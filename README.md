# RustDesk Client Deployment Using PowerShell

RustDesk Client Setup Script.  Downloads and installs the latest RustDesk silently, applies custom server config, generates permanent password, and validates the result.

---

## 🎯 Features

- **Automated Installation**: Downloads and silently installs the latest RustDesk version.
- **Custom Configuration**: Applies a predefined `RustDesk2.toml` with your rendezvous and relay server settings.
- **Secure Password Setup**: Applies perminant password using the `--password` parameter.
- **Version Check**: Skips installation if the correct version is already installed.
- **Log-Based Validation**: Confirms configuration success by parsing RustDesk logs.

---

## 🚀 How It Works

1. **Admin Check**: If not run as administrator, the script will prompt for elevation.
2. **Latest Version**: Always installs the latest Version.
3. **Silent Install**: Downloads and installs RustDesk without user interaction.
4. **Configuration Setup**: Writes the configuration file to both user and service paths.
5. **Password Generation**: Generates random password for you to copy at the end of installation.
6. **Validation via Logs**: Reviews recent logs to confirm that the password and configuration were applied.

---

## 📄 Included Files

- `RustDesk-Client-Deploy.ps1`: Main PowerShell script for installation, configuration, and password setup.


---

## 📋 Requirements

- Windows with PowerShell 5.1 or newer.
- Administrator privileges.
- Internet access to download the RustDesk installer.
- Access to your custom rendezvous and relay server.

---

## 📆 Latest Update

**Last Updated:**  October 20, 2026

---

## 💬 Feedback & Contributions

Your feedback is welcome! If you encounter issues or have suggestions:
