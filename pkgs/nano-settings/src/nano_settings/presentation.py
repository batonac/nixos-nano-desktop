"""How the schema is shown: pages, order, labels, one-line summaries.

The curated half. Types, enum values and defaults come from schema.json and
are never restated here; what this file adds is everything a generated schema
cannot know — which page a setting belongs on, what to call it in two words,
and whether changing it after installation does anything.

The summaries are the ones from the README's configuration table, which is
already the condensed reading of the 30-to-60-line arguments in
modules/options.nix. The full text travels in schema.json and hangs off the
expander under each row, so nothing is lost by summarising here.
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Row:
    key: str
    title: str
    subtitle: str = ""
    # Options that describe the disk as it was formatted. Shown, because
    # "what is this machine" is a fair question to ask a settings app, but
    # not editable: nothing in a rebuild repartitions a running system, so
    # an editable widget here would be a lie.
    frozen: str = ""


@dataclass(frozen=True)
class Group:
    title: str
    rows: list
    description: str = ""


@dataclass(frozen=True)
class Page:
    ident: str
    title: str
    icon: str
    groups: list = field(default_factory=list)
    # Pages whose content is hand-built rather than generated from rows.
    custom: str = ""


INSTALL_TIME = (
    "Set when this machine was installed. Changing it here would not move "
    "any data, so it is shown for reference only."
)

PAGES = [
    Page(
        ident="system",
        title="System",
        icon="preferences-system-symbolic",
        groups=[
            Group(
                title="Identity",
                rows=[
                    Row("hostName", "Computer name", "The name this machine answers to on the network."),
                    Row(
                        "username",
                        "Account name",
                        "Changing this creates a second account rather than renaming this one, "
                        "and the home folder does not follow.",
                        frozen="Set when this machine was installed.",
                    ),
                ],
            ),
            Group(
                title="Time and language",
                rows=[
                    Row("timeZone", "Time zone", "An IANA name, such as America/New_York."),
                    Row("locale", "Locale", "Language and formatting, such as en_US.UTF-8."),
                ],
            ),
            Group(
                title="Advanced",
                rows=[
                    Row(
                        "stateVersion",
                        "State version",
                        "The NixOS release whose defaults this system was built against. "
                        "It is not an upgrade setting and moving it can migrate data formats.",
                        frozen="Fixed at installation on purpose.",
                    ),
                ],
            ),
        ],
    ),
    Page(
        ident="desktop",
        title="Desktop",
        icon="user-desktop-symbolic",
        groups=[
            Group(
                title="Applications",
                rows=[
                    Row(
                        "officeSuite",
                        "Office suite",
                        "Also sets which programs documents open in. LibreOffice is the only "
                        "choice that round-trips .docx and .xlsx faithfully.",
                    ),
                ],
            ),
            Group(
                title="Session",
                description="Features that cost memory or disk while the desktop is running.",
                rows=[
                    Row("features.clipboardHistory", "Clipboard history", "Super+V for history, Super+. for emoji and symbols."),
                    Row("features.thumbnails", "File thumbnails", "Image and video previews in the file manager."),
                    Row("features.audioServer", "Full audio server", "PipeWire. Off means no Bluetooth audio and no per-app volume, but no daemon either."),
                    Row("features.desktopPortal", "Desktop portals", "Only needed for Flatpak apps and screen casting; the native paths cover the rest."),
                    Row("virtualTerminals", "Text consoles", "The Ctrl+Alt+F2 login consoles. Turning them off closes five login doors and gives up a recovery path."),
                ],
            ),
        ],
    ),
    Page(
        ident="hardware",
        title="Hardware",
        icon="video-display-symbolic",
        groups=[
            Group(
                title="Graphics and power",
                rows=[
                    Row("hardwareVideo", "Video acceleration", "The VA-API driver. The two Intel drivers cover different, non-overlapping generations."),
                    Row("firmwareProfile", "Firmware", "Which device firmware to install."),
                    Row("energyPerfBias", "Energy profile", "Performance trades battery life for sustained turbo. Intel only."),
                    Row("features.thermalManagement", "Thermal management", "thermald. Intel only — on AMD it exits and leaves a failed unit behind."),
                    Row("features.processScheduling", "Process priorities", "ananicy-cpp with the CachyOS rules."),
                ],
            ),
            Group(
                title="Peripherals",
                rows=[
                    Row("features.printing", "Printing", "CUPS and the printer setup tool."),
                    Row("features.scanning", "Scanning", "SANE, including driverless network scanners."),
                    Row("features.bluetooth", "Bluetooth", "bluetoothd and the Blueman manager."),
                    Row("features.networkDiscovery", "Network discovery", "Avahi mDNS: .local names and network printer or scanner discovery."),
                    Row("features.virtualFilesystems", "Phones and network shares", "GVFS: trash, MTP and PTP devices, and network shares in the file manager."),
                ],
            ),
        ],
    ),
    Page(
        ident="security",
        title="Security",
        icon="security-high-symbolic",
        groups=[
            Group(
                title="Processor",
                description=(
                    "Both of these trade security for speed on old hardware. They are "
                    "genuine security decisions, not tuning knobs — read the detail "
                    "before turning either one off."
                ),
                rows=[
                    Row("cpuMitigations", "Speculative execution mitigations", "Off adds mitigations=off. Faster, and measurably less safe."),
                    Row("cpuBufferClears", "CPU buffer clearing", "Off adds mds=off. Free only on a processor with no MDS microcode — check before assuming."),
                ],
            ),
            Group(
                title="Browser and logs",
                rows=[
                    Row("browserSiteIsolation", "Browser site isolation", "Firefox Fission. The single largest memory lever here, and a security decision."),
                    Row("disableLogging", "Disable system logging", "Scorched earth: no journal at all. No logs means no diagnosis, and a failing update goes silent."),
                ],
            ),
        ],
    ),
    Page(
        ident="storage",
        title="Storage",
        icon="drive-harddisk-symbolic",
        groups=[
            Group(
                title="Filesystem",
                rows=[
                    Row("compressionLevel", "Compression", "zstd level 1, 6 or 12. Safe to change at any time; it applies to data written from now on."),
                ],
            ),
            Group(
                title="As installed",
                description=INSTALL_TIME,
                rows=[
                    Row("diskDevice", "Disk", frozen=INSTALL_TIME),
                    Row("diskType", "Disk type", "Chose the mkfs and mount profile.", frozen=INSTALL_TIME),
                    Row("swapSizeGiB", "Swap size", "In GiB. Zero means no swap partition and no hibernation.", frozen=INSTALL_TIME),
                    Row("bootMode", "Boot mode", "systemd-boot for UEFI, GRUB for legacy BIOS.", frozen=INSTALL_TIME),
                ],
            ),
        ],
    ),
    Page(ident="software", title="Software", icon="system-software-install-symbolic", custom="software"),
    Page(ident="account", title="Account", icon="avatar-default-symbolic", custom="account"),
    Page(ident="updates", title="Updates", icon="software-update-available-symbolic", custom="updates"),
]


def rows_by_key():
    return {
        row.key: row
        for page in PAGES
        for group in page.groups
        for row in group.rows
    }
