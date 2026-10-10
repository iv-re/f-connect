import Testing

@Suite("Profile reply parsing")
struct ProfileReplyTests {
    @Test func parsesHealthyReplyWithHeader() {
        let reply: [UInt8] = [0xE0, 0xF0, 0x02, 0x0D, 0x00, 0x00, 0x02, 0x1C, 0x02, 0x0D, 0, 0]
        #expect(Ene6K77Profile.slV2.parseRPM(reply) == [525, 0, 540, 525])
    }
    
    /// Regression: the hub left the firmware reply in its buffer and we read it as RPM (shown as 20580 / 50951).
    @Test func rejectsStaleFirmwareReplyAsRPM() {
        let stale: [UInt8] = [0xE0, 0xE0, 0x50, 0x64, 0xC7, 0x07, 0x02, 0x1C, 0x02, 0x0D, 0, 0]
        #expect(Ene6K77Profile.slV2.parseRPM(stale) == nil)
        #expect(Ene6K77Profile.alV2.parseRPM(stale) == nil)
    }
    
    /// The header is the only thing that identifies a reply as "fan speeds" when the values look perfectly plausible.
    @Test func rejectsAForeignReplyWhoseValuesLookPlausible() {
        var foreign = Replies.rpmWithHeader([525, 0, 540, 525])
        foreign[1] = 0x00
        #expect(Ene6K77Profile.slV2.parseRPM(foreign) == nil)
        foreign[1] = 0xE0
        #expect(Ene6K77Profile.alV2.parseRPM(foreign) == nil)
    }
    
    @Test func rejectsImplausibleValuesEvenWithValidHeader() {
        let reply = Replies.rpmWithHeader([0xC7F7, 500, 500, 500])
        #expect(Ene6K77Profile.slV2.parseRPM(reply) == nil)
    }
    
    @Test func acceptsBoundaryRPM() {
        #expect(Ene6K77Profile.slV2.parseRPM(Replies.rpmWithHeader([10_000, 0, 0, 0])) == [10_000, 0, 0, 0])
        #expect(Ene6K77Profile.slV2.parseRPM(Replies.rpmWithHeader([10_001, 0, 0, 0])) == nil)
    }
    
    @Test func rejectsTruncatedReply() {
        #expect(Ene6K77Profile.slV2.parseRPM([0xE0, 0xF0, 0x02]) == nil)
        #expect(Ene6K77Profile.slV2.parseRPM([]) == nil)
        #expect(Ene6K77Profile.slInfinity.parseRPM([0xE0, 0x02, 0x0D]) == nil)
    }
    
    @Test func headerlessModelsReadValuesFromOffsetOne() {
        let reply: [UInt8] = [0xE0, 0x02, 0x0D, 0x00, 0x00, 0x02, 0x1C, 0x02, 0x0D, 0, 0]
        for p in [Ene6K77Profile.slInfinity, .slV1, .alV1] {
            #expect(p.parseRPM(reply) == [525, 0, 540, 525])
        }
    }
    
    @Test func headerlessModelsRejectAForeignReplyByPlausibility() {
        // Without a header the only protection is the plausibility check: E0 E0 50 .. decodes to a huge number.
        let stale: [UInt8] = [0xE0, 0xE0, 0x50, 0x64, 0xC7, 0x07, 0x02, 0x1C, 0x02, 0x0D, 0, 0]
        #expect(Ene6K77Profile.slInfinity.parseRPM(stale) == nil)
    }
    
    @Test func parsesFirmwareReply() {
        let info = Ene6K77Profile.parseFirmware(Replies.firmware())
        #expect(info == Ene6K77Profile.FirmwareInfo(majorID: 100, minorID: 199, fineTune: 7))
    }
    
    @Test func rejectsNonFirmwareReplyAsFirmware() {
        #expect(Ene6K77Profile.parseFirmware(Replies.rpmWithHeader([500, 500, 500, 500])) == nil)
        #expect(Ene6K77Profile.parseFirmware([0xE0, 0xE0, 0x50]) == nil)
        #expect(Ene6K77Profile.parseFirmware([]) == nil)
    }
    
    @Test func versionStringOfTheDevelopmentHub() {
        let info = Ene6K77Profile.parseFirmware(Replies.firmware())!
        #expect(Ene6K77Profile.slV2.versionString(for: info) == "v0.7")   // matches "LianLi-UNI FAN-SL V2-v0.7"
    }
}

@Suite("Firmware version decoding")
struct FirmwareSchemeTests {
    @Test func standardSchemeSplitsDecimalDigits() {
        #expect(FirmwareScheme.slV1.version(fineTune: 0x15, minorID: 194) == (1, 5))
        #expect(FirmwareScheme.alV2.version(fineTune: 0x07, minorID: 198) == (0, 7))
        #expect(FirmwareScheme.slV2.version(fineTune: 0x24, minorID: 197) == (2, 4))
    }
    
    @Test func lowNibbleAboveNineIsInvalid() {
        #expect(FirmwareScheme.slV1.version(fineTune: 0x0A, minorID: 194) == (0, 0))
        #expect(FirmwareScheme.alV2.version(fineTune: 0x1F, minorID: 198) == (0, 0))
    }
    
    @Test func slV2QuirkForMinorID199() {
        #expect(FirmwareScheme.slV2.version(fineTune: 0, minorID: 199) == (0, 5))
        #expect(FirmwareScheme.slV2.version(fineTune: 3, minorID: 199) == (0, 0))
        #expect(FirmwareScheme.slV2.version(fineTune: 5, minorID: 199) == (0, 0))
        #expect(FirmwareScheme.slV2.version(fineTune: 6, minorID: 199) == (0, 6))
        #expect(FirmwareScheme.slV2.version(fineTune: 3, minorID: 197) == (0, 3), "quirk applies to 199 only")
    }
    
    @Test func alV1AddsTwoFromFineTuneEight() {
        #expect(FirmwareScheme.alV1.version(fineTune: 5, minorID: 195) == (1, 0))
        #expect(FirmwareScheme.alV1.version(fineTune: 8, minorID: 195) == (1, 0))
        #expect(FirmwareScheme.alV1.version(fineTune: 0x10, minorID: 195) == (1, 2))
    }
    
    @Test func slInfinityQuirks() {
        #expect(FirmwareScheme.slInfinity.version(fineTune: 2, minorID: 196) == (0, 0))
        #expect(FirmwareScheme.slInfinity.version(fineTune: 20, minorID: 196) == (0, 0))
        #expect(FirmwareScheme.slInfinity.version(fineTune: 13, minorID: 196) == (1, 4))
        #expect(FirmwareScheme.slInfinity.version(fineTune: 0x2A, minorID: 196) == (0, 0))
        #expect(FirmwareScheme.slInfinity.version(fineTune: 0x24, minorID: 196) == (2, 4))
    }
}
