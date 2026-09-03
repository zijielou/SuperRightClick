<div align="center">
  <img src="./App/Resources/AppIcon-360.png" width="180" alt="SuperRightClick app icon">
  <h1>SuperRightClick</h1>
  <p><strong>A clean, configurable, and privacy-focused context menu extension for macOS Finder</strong></p>

  <p>
    <a href="./README.md"><img src="https://img.shields.io/badge/简体中文-Switch-64748B?style=for-the-badge" alt="简体中文"></a>
    <a href="./README_EN.md"><img src="https://img.shields.io/badge/English-Current-4F46E5?style=for-the-badge" alt="English"></a>
  </p>

  <p>
    <a href="https://github.com/zijieloooooou/SuperRightClick/releases/latest"><img src="https://img.shields.io/badge/Download_Latest-DMG-2563EB?style=for-the-badge&logo=github" alt="Download the latest DMG"></a>
  </p>

  <p>
    <img src="https://img.shields.io/badge/macOS-15.0%2B-111827?style=flat-square&logo=apple" alt="macOS 15.0+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-M%20Series%20only-111827?style=flat-square&logo=apple" alt="Apple Silicon M series only">
    <img src="https://img.shields.io/badge/version-0.2.0-2563EB?style=flat-square" alt="Version 0.2.0">
  </p>
</div>

SuperRightClick enhances the macOS Finder context menu through a Finder Sync extension. It keeps common tasks—creating files, copying paths, moving items, converting images, and more—inside Finder, while allowing menu actions, names, order, and icons to be customized.

## Features

### Create Files

- Built-in TXT, RTF, XML, and Markdown templates
- Import any file as a custom template
- Enable, rename, reorder, or promote templates to the top-level menu
- Automatically enter Finder's rename mode after creation
- Optionally open new files or play a creation sound

> Automatic rename after creation requires Accessibility permission for SuperRightClick.

### File and Folder Actions

- Copy a file path, filename, or the current folder path
- Cut, paste, move, or copy items to configured destinations
- View file information and hashes
- Create desktop aliases or folders based on filenames
- Apply a custom folder icon
- Hide or reveal selected items
- Open items with Terminal, Visual Studio Code, or custom apps
- Manage favorite folders and move/copy destinations

### Image Tools

- Convert images to HEIC, JPG, or PNG
- Configure lossy image quality and the background color used for transparent JPG input
- Set an image as desktop wallpaper, optionally on every display
- Save converted images next to the source and append a number when a name already exists

### Fully Configurable

- Enable or disable each menu action independently
- Rename and reorder actions by dragging
- Show, hide, or replace individual menu icons
- Group file actions, Open With apps, and image conversion into submenus
- Show or hide the menu bar item
- Exclude selected folders and their descendants

### Safety and Privacy

- All file operations run locally
- The current implementation contains no networking, telemetry, or file-upload logic
- Bulk visibility changes, permission changes, folder dissolution, and permanent deletion are disabled by default
- Permanent deletion bypasses Trash and is confirmed in the foreground app by default; per-operation confirmation can be explicitly disabled under Advanced
- No per-operation log is continuously appended; only required preferences and a small amount of state are stored

## Requirements

- **Processor: Apple Silicon (M series, arm64)**
- macOS 15.0 or later
- Finder Extension permission
- Accessibility permission for automatic rename after file creation
- Full Disk Access may be required when working in protected locations

> [!IMPORTANT]
> The current app and DMG contain only the `arm64` architecture and **will not run on Intel Macs**. An Intel build is not currently provided.

## Download and Install

No Xcode installation or local build is required. Download the DMG and install the app directly:

<p>
  <a href="https://github.com/zijieloooooou/SuperRightClick/releases/latest"><img src="https://img.shields.io/badge/Open_GitHub_Releases-Download_Latest_DMG-2563EB?style=for-the-badge&logo=github" alt="Open GitHub Releases and download the latest DMG"></a>
</p>

1. Open the download page above and download the `.dmg` file under the latest release's **Assets** section.
2. Open the DMG and drag `SuperRightClick.app` into Applications.
3. Launch SuperRightClick.
4. On the Status page, select **Open Finder Extension Settings** and enable **SuperRightClick Finder Extension**.
5. To enter rename mode automatically after creating a file, select **Request Accessibility Access** and grant permission.
6. Return to Finder and right-click a file, folder, or empty area.

> [!NOTE]
> The current DMG has not been notarized by Apple, so macOS will report that the developer cannot be verified. To install, go to **System Settings → Privacy & Security** and click **Open Anyway**. Download the DMG only from this project's GitHub Releases and install it after confirming the source is trustworthy.

## Configuration

Open the SuperRightClick app to configure these sections:

| Section | Main settings |
| --- | --- |
| Status | Finder extension, Accessibility, and Full Disk Access |
| New File | Templates, automatic opening, and creation sound |
| Folders | Favorite folders, move/copy destinations, and Open With apps |
| Menu | Action visibility, names, order, icons, language, and grouping |
| Images | Conversion quality, JPG background color, and wallpaper displays |
| Advanced | High-risk actions, operation behavior, and excluded folders |

## FAQ

### The Finder context menu does not appear

Make sure the Finder extension is enabled, then run `killall Finder` or sign out and back in.

### A newly created file does not enter rename mode

Grant Accessibility permission on SuperRightClick's Status page. macOS may require permission again after the app is updated or reinstalled.

### Is permanent deletion safe?

It is disabled by default. When enabled, files are deleted directly without being moved to Trash, with confirmation shown by the foreground app by default. Per-operation confirmation can be disabled under Advanced; once disabled, choosing permanent deletion acts immediately and cannot be undone. Keep appropriate backups.

### Does the app continuously accumulate operation logs?

No. The current release has no log system that appends an entry for every file operation, so normal long-term use does not create an ever-growing operation log.

## Feedback

If you find a problem or have a feature request, please open an issue in [GitHub Issues](https://github.com/zijieloooooou/SuperRightClick/issues).
