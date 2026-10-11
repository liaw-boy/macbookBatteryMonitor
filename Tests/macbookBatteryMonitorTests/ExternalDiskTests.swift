import Foundation

final class ExternalDiskTests {
    private func traits(_ mount: String, node: String = "/dev/disk4s1", internal isInternal: Bool = false,
                        proto: String? = "USB") -> ExternalMountTraits {
        ExternalMountTraits(mountPoint: mount, deviceNode: node, isInternal: isInternal, protocolName: proto)
    }

    func testExternalDriveIsListed() {
        XCTAssertTrue(ExternalDisk.isExternal(traits("/Volumes/Backup")))
        XCTAssertTrue(ExternalDisk.isExternal(traits("/Volumes/SD", proto: "Secure Digital")))
        XCTAssertTrue(ExternalDisk.isExternal(traits("/Volumes/SSD", proto: nil)))
    }

    func testInternalSystemDiskImageAndNetworkAreExcluded() {
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/", node: "/dev/disk3s1s1", internal: true, proto: "Apple Fabric")))
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/System/Volumes/Data", node: "/dev/disk3s5", internal: true)))
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/Volumes/Internal2", internal: true)))
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/Volumes/Installer", proto: "Disk Image")))
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/Volumes/share", node: "//user@server/share")))
        XCTAssertTrue(!ExternalDisk.isExternal(traits("/Volumes/NFS", node: "server:/export")))
    }

    func testUsedSpaceNeverUnderflows() {
        XCTAssertEqual(ExternalVolume(mountPoint: "/Volumes/A", name: "A", total: 100, available: 30).used, 70)
        XCTAssertEqual(ExternalVolume(mountPoint: "/Volumes/A", name: "A", total: 100, available: 130).used, 0)
    }

    func testDeviceNodeValidationAndHealthParsing() {
        XCTAssertTrue(ExternalDisk.isValidDeviceNode("/dev/disk5"))
        XCTAssertTrue(ExternalDisk.isValidDeviceNode("/dev/disk5s2"))
        XCTAssertTrue(ExternalDisk.isValidDeviceNode("/dev/disk12s1s3"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk5s"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk5; rm -rf /"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("//server/share"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/rdisk5"))
        XCTAssertEqual(DiskHealth.parse("Verified"), .verified)
        XCTAssertEqual(DiskHealth.parse("Failing"), .failing)
        XCTAssertEqual(DiskHealth.parse("About to Fail"), .failing)
        XCTAssertEqual(DiskHealth.parse("Not Supported"), .unsupported)
        XCTAssertEqual(DiskHealth.parse(nil), .unsupported)
    }

    func testNonASCIIDigitsAndLabelSanitizing() {
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk\u{0665}"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk5s\u{00B2}"))
        XCTAssertTrue(!ExternalDisk.isValidDeviceNode("/dev/disk" + String(repeating: "x", count: 3)))
        XCTAssertEqual(ExternalDisk.displayName("Photo\u{202E}_1T\u{0007}"), "Photo_1T")
        XCTAssertEqual(ExternalDisk.displayName("\u{202E}\u{0000}"), "外接磁碟")
        XCTAssertEqual(ExternalDisk.displayName(String(repeating: "a", count: 200)).count, 64)
    }
}
