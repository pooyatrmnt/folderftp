# Local FTP Share

Local FTP Share adds **Share via local FTP** to the Windows folder context menu. It starts a temporary, read-only FTP server for the selected directory with anonymous access.

## Install

1. Extract this project to a permanent or temporary folder.
2. Double-click `Install.cmd`.
3. Accept the Windows administrator prompt. It creates a firewall rule restricted to **Private** networks and the **local subnet**.

The program itself is installed for the current Windows user in `%LOCALAPPDATA%\LocalFtpShare`. The installer source folder can then be deleted.

## Share a folder

1. Right-click the folder in File Explorer.
2. On Windows 11, select **Show more options**.
3. Select **Share via local FTP**.
4. Give the displayed address to the other device. Select **Anonymous login** in the FTP client. The address is also copied to the clipboard.
5. Close the server window, or press **Ctrl+C**, to stop sharing.

The server listens on TCP port `2121` and uses passive ports `50000-50099`. It permits listing and downloading only. Uploads, deletion, folder creation, and renaming are rejected. Multiple clients can browse and download concurrently.

## Uninstall

Double-click `Uninstall.cmd` and accept the administrator prompt. This removes the context-menu item, installed scripts, and firewall rule.

## Security

FTP does not encrypt its password or file traffic. Use this tool only on a trusted home or office LAN. Keep the Windows network profile set to **Private**, never forward these ports through a router, and close the server window when finished.

