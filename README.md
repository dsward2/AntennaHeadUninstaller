# AntennaHead Uninstaller

A small macOS app that removes **AntennaHead** and **ControlBooth** and the data they
leave in your user account, for cleaning a Mac between test installs.

Everything is moved to the **Trash**, never deleted outright, and the moves are done
through Finder so **Put Back** works: open the Trash, select an item, choose
*File ▸ Put Back*.

## What it removes

| | |
|---|---|
| Apps | `/Applications/AntennaHead.app`, `/Applications/ControlBooth.app` (also `~/Applications`) |
| Per-app data | `~/Library/Containers/<id>`, `Application Support/AntennaHead` and `/ControlBooth`, `Caches`, `WebKit`, `HTTPStorages`, `Preferences/<id>.plist`, `Application Scripts/<id>`, `Saved Application State`, `Logs` |
| Shared | the App Group container `group.com.dsward.antennahead`, and its `Application Scripts` folder |
| Optional | **Recordings** (inside the group container; *kept by default*), the **text-to-speech folder** (a folder you pick; AntennaHead doesn't record where it is), the **"AntennaHead Self-Signed" TLS certificate** in your login keychain, and the **Gqrx for AntennaHead** app |

Only items that actually exist on that Mac are listed. AntennaHead and ControlBooth are
quit first.

### Not touched
- `~/.config/gqrx` and Gqrx's preferences. Gqrx for AntennaHead shares them with the
  original Gqrx, so only the fork's app bundle can be offered (unticked by default).
- The saved **HTTP password** in the keychain (`com.dsward.AntennaHead.httpAuth`). It is
  in a data-protection keychain item that only AntennaHead itself can delete. Clear it
  in AntennaHead's settings before uninstalling if that matters.
- The keychain certificate can't be restored with Put Back (it isn't a file).

## Permissions

The first run asks to control **Finder**. That is how the Trash moves are done, and it
is why Full Disk Access isn't needed even for the protected `Containers` and
`Group Containers` folders. If you decline, allow it under System Settings ▸ Privacy &
Security ▸ Automation.

## How "keep recordings" works

Recordings live at `Group Containers/group.com.dsward.antennahead/Recordings`. With
Recordings unticked, everything in the group container **except** `Recordings` is
trashed; ticked, the whole container goes.

## Building

Open `AntennaHeadUninstaller.xcodeproj` (macOS 14+). The unit tests cover the item
catalog, the keep-recordings planning, the text-to-speech folder safety check and
failure handling; they never touch real files.

Release builds are Developer ID signed and notarized like the other apps in the
[AntennaHead workspace](https://github.com/dsward2/antennahead-workspace).
