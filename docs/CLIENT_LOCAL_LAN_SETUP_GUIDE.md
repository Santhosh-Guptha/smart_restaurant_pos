# SmartBizz POS — Client Local LAN Setup Guide

> **Audience:** restaurant and shop owners, store managers, on-site IT.
> **Platforms:** Windows 10/11 host till; Android / iOS / Windows devices running the SmartBizz app as waiter pads, kitchen screens, customer displays or extra billing tills.
> **Storage mode:** `LOCAL_NETWORK` — the host till runs the Local LAN Hub inside the app; the other devices pair with it over the store Wi-Fi.

---

## Table of contents
1. [How it works](#1-how-it-works)
2. [Hardware and network](#2-hardware-and-network)
3. [Set up the host till](#3-set-up-the-host-till)
4. [Pair a second device](#4-pair-a-second-device)
5. [Device limit and roles](#5-device-limit-and-roles)
6. [Router setup: static IP for the host](#6-router-setup-setting-up-a-static-ip-dhcp-reservation)
7. [When something goes wrong](#7-when-something-goes-wrong)
8. [Backups](#8-backups)
9. [Quick reference](#9-quick-reference)

---

## 1. How it works

- **One host.** The till that holds the licence runs the **Local LAN Hub** (HTTP on port `8080`). It keeps the only copy of tables, dine-in orders (KOTs), kitchen status and the customer display.
- **Every other device runs the SmartBizz app** and pairs with the host once, using a 6-digit PIN shown on the host screen. There is no browser page to open and no second port.
- **The host is the ledger.** A paired device shows what the host has and sends its changes to the host. If two devices change the same thing, the host's version stands.
- **Live updates.** Paired devices hold an open request to the host and are told as soon as something changes; a waiter's order normally appears on a paired kitchen screen within about a second. The kitchen chime plays on the host's kitchen screen and on paired kitchen screens.
- **No internet needed** for any of this. The hub only listens on the store LAN; it is not reachable from outside the router unless you forward the port (do not).

What runs where:

| Device | Runs | Reads from | Writes to |
|---|---|---|---|
| Host till (OWNER) | Billing, tables, kitchen, hub | its own ledger | its own ledger |
| Waiter pad (WAITER) | Table picker, order taking | host | host |
| Kitchen screen (KITCHEN) | Kitchen display | host | host (status changes) |
| Customer display | Customer-facing screen | host | — |
| Second till (BILLING / MANAGER) | Counter billing | host (tables, orders) | host |

### Data: where it lives, and the optional sync to your Google Sheet

- The hub serves **one outlet**. The PIN panel names it ("Outlet: …"); devices that pair with that PIN join that outlet. A store with several outlets runs one host PC per outlet, and the hub stops if the host switches outlet while it runs (start it again on the new outlet).
- **Sync to your own Google Sheet (optional, host only).** If the licence also has the cloud ledger (your store sheet in your own Google Drive) and the sheet is registered, the Local LAN Hub panel on the host shows **"Also sync to my Google Sheet when online"** (off by default). When it is on, every KOT and bill that reaches the hub — from the host or from any paired device — is also written to your store sheet whenever the host PC has a connection, through the same queue an own-Drive store uses. The hub never waits for it: a write that cannot go out is queued and sent later, in order. Paired devices never sync on their own; they only talk to the host.
- What the switch does **not** do: it does not fetch anything from the cloud (menu, settings and staff still come from the host), it writes a KOT when it first reaches the hub and again when it is settled (kitchen stage changes in between are not written), and it needs the host to be online at some point — a host that is never connected keeps the queue on disk. Your business data stays in your own Google Drive; only limited usage analytics such as bill counts are collected.

---

## 2. Hardware and network

### Host till
| Component | Minimum | Recommended |
|---|---|---|
| OS | Windows 10 64-bit (1909+) | Windows 11 Pro |
| CPU | Intel Core i3 / AMD Ryzen 3 | Core i5 (8th gen+) or similar |
| RAM | 4 GB | 8 GB |
| Storage | 20 GB free on `C:` | SSD |
| Network | 100 Mbps Ethernet or 802.11n Wi-Fi | **Ethernet cable to the router** |

> [!TIP]
> Plug the host into the router with a cable. Wi-Fi works, but a cabled host is not affected by microwave ovens, fridges or walls between it and the router.

### Store Wi-Fi router
- Dual band (2.4 / 5 GHz); put the tablets on 5 GHz where the signal allows.
- A private SSID for the POS devices (for example `SmartBizz_POS_5G`); do not give customers that password.
- Any common brand works (TP-Link, Netgear, D-Link, Asus, JioFiber, Airtel Xstream, ISP ONUs). See section 6 for the static-IP step.
- Some routers have **AP isolation** / **client isolation** on guest networks, which stops devices from talking to each other. Use the main network, not a guest network, for the POS devices.

### Other devices
- Android 8+ tablet or phone, iPad (iOS 13+), or a Windows laptop — each with the **SmartBizz app installed**. A browser is not enough.

---

## 3. Set up the host till

1. Install SmartBizz and sign in with the store's licence (or activate the licence token) on the host.
2. Open **Settings → Store Configuration → KOT & Receipts**. In **Self-Hosted Local LAN Hub Server**, switch the hub **on**. The card shows:
   - the **host address** (`192.168.x.x:8080`),
   - the **6-digit pairing PIN** in large type,
   - **Devices n / max** — how many devices are in use against the licence (the host counts as one),
   - the **paired devices** list with a **Remove** button on each,
   - **Rotate PIN** (issues a new PIN; already-paired devices stay paired),
   - **Show Satellite Pairing QR** (same address and PIN as a QR code).
3. When Windows asks whether to allow SmartBizz on the network, choose **Private networks** and allow it. If the prompt never appeared, run this once in an **administrator** PowerShell:
   ```powershell
   netsh advfirewall firewall add rule name="SmartBizz POS LAN Hub (8080)" dir=in action=allow protocol=TCP localport=8080 profile=private,domain
   ```
4. Make sure the Windows network profile for the store network is **Private** (Settings → Network & Internet → the connected network → Network profile type).
5. Give the host a fixed address on the router (section 6) so the tablets do not have to be re-pointed after a router restart.
6. Press **Test LAN Ping** on the card; it should report the server is responding.

Keep the host running during service. When the host app is closed, paired devices show "host offline" and cannot take or update orders until it is back.

---

## 4. Pair a second device

On the tablet, phone or second till:

1. Install SmartBizz and open it. On the start screen choose **Free trial / satellite**, then the device role **Satellite** and **Connect to host**.
2. Enter the **host address** exactly as shown on the host card (for example `192.168.1.150:8080`), or scan the QR code from the host.
3. Pick the **role** for this device: WAITER, KITCHEN, BILLING or MANAGER (restaurants) — BILLING or MANAGER (shops). See section 5.
4. Type the **6-digit PIN** from the host screen and press **Connect**.
5. The device reads the store's name, trade and features from the host and opens with that role's screens. It keeps the pairing across restarts; the PIN is needed only once.

After pairing, the device appears on the host's **Paired devices** list. **Remove** on the host revokes it: the device drops back to "pair this device" and has to enter the PIN again.

> [!NOTE]
> Five wrong PINs within a minute lock pairing on the host for a minute. The PIN itself is only ever shown on the host screen; it is not sent to any device.

---

## 5. Device limit and roles

- **Device limit.** The licence's `maxDevices` is the total number of devices, **host included**. With `maxDevices = 3`, the host plus two paired devices are allowed. The host refuses a pairing beyond that with **"Device limit reached"**.
- **Roles by trade.**
  - **Restaurant:** WAITER, KITCHEN, BILLING, MANAGER.
  - **Shops** (supermarket, pharmacy, bakery, …): BILLING and MANAGER only. The host refuses WAITER or KITCHEN for a shop.
  - **Kirana** is single-device and has no hub.
- Paired devices use the host's licence; they do not need one of their own.

### "Device limit reached"
1. On the host card, look at **Devices n / max** and the paired list.
2. **Remove** a device that is no longer in use (an old tablet, a re-installed phone that paired twice).
3. Try again on the new device. If every slot is genuinely in use, ask for a higher tier from **Plan & Billing** on the host; the new limit applies once the licence is refreshed.

### "Wrong pairing PIN"
- Read the PIN from the host card again; it changes whenever someone presses **Rotate PIN**.
- After five wrong attempts wait a minute, then enter the current PIN.

### "Could not reach the host"
See section 7.

---

## 6. Router Setup: Setting Up a Static IP (DHCP Reservation)

> [!IMPORTANT]
> **Why is DHCP Reservation Essential?**  
> By default, standard Wi-Fi routers dynamically change device IP addresses whenever the router restarts or the lease expires. If your Host PC's IP changes from `192.168.1.150` to `192.168.1.155`, tablets will lose connection until their URL is updated.  
> A **DHCP Reservation (Static IP)** tells the router to keep handing the same address to the host PC, so the address typed into the tablets stays valid across router restarts.

### Step 1: Find the Host PC's Physical MAC Address
Run this quick command in Windows PowerShell on the host PC:
```powershell
getmac /v /fo list
```
Look for the `Physical Address` of your active Wi-Fi or Ethernet adapter (e.g., `A4-B1-C2-D3-E4-F5`).

---

### Step 2: Configure Your Router

#### Option 1: TP-Link Routers (Archer / Deco / WR841)
1. Open a browser and enter `http://192.168.0.1` or `http://192.168.1.1` (or `tplinkwifi.net`).
2. Log in with your router password (default is often printed on the back of the router).
3. Navigate to **Advanced** -> **Network** -> **DHCP Server** -> **Address Reservation**.
4. Click **Add** or **+**.
5. Enter:
   - **MAC Address:** Your Host PC's MAC address (e.g. `A4-B1-C2-D3-E4-F5`).
   - **Reserved IP Address:** `192.168.1.150` (or your current preferred LAN IP).
   - **Status:** Enabled.
6. Click **Save** and reboot the router.

#### Option 2: JioFiber Home Gateway
1. Open `http://192.168.29.1` in your browser.
2. Log in (default username: `admin`, password: `Jiocentrum` or custom).
3. Go to **Network** -> **LAN** -> **DHCP Static IP Lease**.
4. Select your Host PC name from the list and assign a static IP address.
5. Click **Apply**.

#### Option 3: Airtel Xstream Fiber
1. Open `http://192.168.1.1` in your browser.
2. Log in (default: `admin` / `admin`).
3. Navigate to **Network** -> **LAN** -> **DHCP Server Binding**.
4. Add your Host PC's MAC Address and map it to `192.168.1.150`.
5. Click **Save**.

#### Option 4: Netgear & D-Link
1. Open `http://192.168.1.1` or `http://routerlogin.net`.
2. Go to **Setup** / **Advanced** -> **LAN Setup** -> **Address Reservation**.
3. Click **Add**, select your Host PC, choose the IP, and click **Apply**.

---

## 7. When something goes wrong

### The tablet says "Could not reach the host"
1. **Same network?** The tablet must be on the store Wi-Fi, not mobile data and not a guest network with client isolation. Check the Wi-Fi name on the tablet.
2. **Host address.** Compare the address on the host card with what was typed. If the host's IP changed (router restart without a reservation), the host card shows the new one; re-enter it on the tablet (**Satellite → Connect to host** again with the current PIN).
3. **Hub switched on?** The host card must show the hub as active; it does not start by itself if the app was closed and reopened with the switch off.
4. **Firewall.** Section 3, steps 3–4. The quickest check is on the host itself: **Test LAN Ping**.
5. **Port in use.** If the hub fails to start, another program (XAMPP, Tomcat, IIS, a proxy) may be on port 8080. Find it with `netstat -ano | findstr :8080` in PowerShell and stop that program, or run the hub on another port and pair the devices with that port.

### Host offline during service
Paired devices keep showing what they last received and mark themselves as disconnected. Orders cannot be taken or moved until the host is back; once it is, the devices reconnect on their own and catch up with the host's state.

### A device was paired twice
Each pairing takes a slot. Remove the stale entry on the host card.

### The kitchen screen does not chime on a paired device
Check the kitchen screen's own sound settings (chime / voice toggles on that screen) and the tablet's volume. The host's kitchen screen chimes independently.

### Orders differ between two devices
The host's version wins. Pull-to-refresh on the device, or wait a few seconds; if the device is disconnected, fix the connection first (above).

---

## 8. Backups

All store data lives on the host till. Paired devices hold only a working copy that is replaced by the host's data whenever they reconnect, so back up the **host** (a paired device shows "Backups are taken on the host PC" instead of Backup & restore). The backup includes the hub's tables and orders but never the pairing PIN or the paired devices' tokens, so after a restore on another PC the devices pair again:

1. **End of day:** on the host, **Settings → Data & Backup → Generate Local Snapshot**.
2. **Weekly:** copy the backup folder to a USB drive kept away from the till.
3. **Replacement PC:** install SmartBizz, sign in with the licence, restore the latest snapshot from **Data & Backup**, switch the hub on, then pair the devices again with the new host's address and PIN (the old pairings do not carry over).

---

## 9. Quick reference

| Item | Value |
|---|---|
| Hub port | TCP `8080` (inbound, private profile) |
| Pairing | 6-digit PIN from the host card, once per device |
| Device count | host + paired devices ≤ licence `maxDevices` |
| Restaurant roles | WAITER, KITCHEN, BILLING, MANAGER |
| Shop roles | BILLING, MANAGER |
| Data owner | the host till |
| Reachability check | **Test LAN Ping** on the host card |

### Support
- Documentation: `docs/README.md`
- Technical support: `support@smartbizz.devmonks.space`
- Platform admin console: `smartbizz.devmonks.space`
