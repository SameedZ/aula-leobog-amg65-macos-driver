# Local official driver files

Keep the official LEOBOG AMG65 Windows driver installer and its extracted files in this folder for local development only.

Expected layout:

```text
local/official-driver/
├── LEOBOG AMG65 Driver-1.0.3.1.exe
└── extracted/
    └── app/
        ├── KeyboardLayout.xml
        ├── font/
        ├── gif/
        └── skins/
```

The macOS app build uses selected artwork, fonts, and keyboard layout data from `extracted/app`. These are third-party assets. The installer and extracted files are intentionally excluded from Git; do not publish or redistribute them without permission from their rights holders.
