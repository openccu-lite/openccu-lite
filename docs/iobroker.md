# ioBroker: moving from a CCU3 or OpenCCU to openccu-lite

*English — the German version is [iobroker.de.md](iobroker.de.md).*

This guide is for an ioBroker that talks to a CCU3 or OpenCCU today through
[ioBroker.hm-rpc](https://github.com/ioBroker/ioBroker.hm-rpc), one instance per interface (BidCos-RF, HmIP-RF, perhaps
BidCos-Wired, VirtualDevices or CUxD), and usually [ioBroker.hm-rega](https://github.com/ioBroker/ioBroker.hm-rega)
for names, rooms, system variables and programs. It keeps one hm-rpc instance per interface, as before. The switch of
the CCU itself is described in [switching.md](switching.md); this page covers the ioBroker side.

The short version: **each existing hm-rpc instance is switched to the daemon *openccu-lite* and paired with the
system. Its objects keep their ids, and with them history settings, aliases, scripts and visualisations.** hm-rega and
CUxD go.

## What changes

- **hm-rpc stays, with the daemon *openccu-lite*.** The instance reaches the interface through the system's *lite-rpc*
  on its web port (HTTPS, 443) with an API token of its own; the events come as a stream the instance opens itself.
  There is no callback any more: no adapter address, no adapter port, no `init`, and nothing to open in a firewall
  towards ioBroker. ioBroker may run behind a router or in a Docker container.
- **hm-rega goes.** openccu-lite has no ReGa: no system variables, no programs, no HM-Script, no favourites, no
  diagrams. **Names, rooms and functions** now come from the system's metadata, through hm-rpc itself (the option
  *Take names, rooms and functions from the system*). They are taken over from the CCU's ReGa when it is switched.
- **CUxD goes.** It needs the ReGa and does not run on openccu-lite; its hm-rpc instance has nothing to connect to.
- **The devices stay.** The switch keeps the pairings, the keys and the device addresses, so the objects
  `hm-rpc.<n>.<address>.<channel>.<DATAPOINT>` keep their ids.

## Before you start

**Versions:**

| Component | Needed | Notes |
| --- | --- | --- |
| ioBroker.hm-rpc | **4.3.0 or later** | the first version with the daemon *openccu-lite*; see [Known limits](#known-limits) for a device paired later |
| ioBroker.discovery | 5.4.0 or later | only for proposals of new instances; not needed for converting existing ones |
| js-controller | 6.0.11 or later | hm-rpc's requirement |
| admin | 7.6.20 or later (8.0.0 for discovery 5.4) | |
| Node.js | 22.19.0 or later | hm-rpc's and discovery's requirement |

At the time of writing (November 2026) ioBroker's **stable** repository still offers hm-rpc 4.1.2 and discovery 5.2.0;
hm-rpc 4.3.0 and discovery 5.4.1 are in the **beta (latest)** repository. Switch the repository under *System settings →
Repositories* to install them, or wait until they reach stable.

**Backups:**

- **ioBroker:** a full backup (for example with BackItUp), so the objects, the states and the adapter settings can
  come back.
- **The CCU:** a backup (`.sbk`) and a copy of the whole system, as [switching.md](switching.md#check-before-switching)
  describes. The backup is the way back.

## Step 1: switch the CCU

Switch the CCU to openccu-lite as [switching.md](switching.md) describes: an update over the existing system, or a new
installation with an import of the CCU's backup. Either way the devices stay paired, their addresses stay the same,
and the names, rooms and functions are taken over from the ReGa.

Right after the switch:

- **The classic hm-rpc instances may keep running for now.** If OpenCCU's firewall let clients reach the XMLRPC ports,
  openccu-lite switches classic RPC on (see [What changes on the first start](switching.md#what-changes-on-the-first-start)),
  and the classic instances connect as before. Otherwise they cannot connect until they are converted in step 2.
- **hm-rega cannot connect any more.** Stop its instance; it is removed in step 3.
- **CUxD** is listed on the system's Addons page as *disabled, incompatible*. Stop its hm-rpc instance.

## Step 2: convert each hm-rpc instance

Do this for each hm-rpc instance of an interface the system runs (BidCos-RF, HmIP-RF, BidCos-Wired, VirtualDevices).
**Convert the existing instance; do not create a new one:** a new instance number means new object ids
(`hm-rpc.5.…` instead of `hm-rpc.1.…`), and history settings, aliases and scripts would point at the old ones.

1. **Check that the system allows pairing:** on the system, *System → Remote access*, *Allow programs to ask for
   access* (on by default). The pairing request must come from the system's local networks.
2. In ioBroker, open *Instances*, then the settings of the hm-rpc instance. **The instance must be running** (the
   pairing runs in it; a classic instance that cannot reach its CCU any more is fine).
3. **Daemon:** select *openccu-lite*. The settings for the callback (adapter address, adapter port, protocol) disappear.
4. **HomeMatic Address:** the system's address or name, as before.
5. Under *Additional settings* tick **Use https**. The port follows by itself: 443 (80 without HTTPS).
6. Back under *Main settings*: **Interface** is the interface of the system this instance connects (`HmIP-RF`,
   `BidCos-RF`, `BidCos-Wired`, `VirtualDevices`), one per instance. Check it: an instance that used to be *rfd* is
   `BidCos-RF`, *hs485d* is `BidCos-Wired`, *Virtual Devices* is `VirtualDevices`.
7. **Take names, rooms and functions from the system** is ticked by default; see
   [Rooms and functions](#rooms-and-functions) before you keep it.
8. Press **Pair**. A six-digit code appears below the button, with a link to the system's Status page.
9. On the system's **Status page**, as one of its administrators: the request names the program
   (`ioBroker.hm-rpc`), the instance (`hm-rpc.<n> on <host>`) and the access it asks for (devices: configure, names:
   read). **Compare the code** with the one in ioBroker, then approve it.
10. ioBroker asks *Save configuration?*: save. The token and the fingerprint of the system's certificate are stored in
    the instance, and it restarts on lite-rpc. Its log says `lite-rpc client is connecting to https://<address> for the
    interface <interface>`, then `Connected`.

Each instance pairs on its own and gets a token of its own (the system's *Remote access* page lists them as paired
programs). Instead of pairing, an API token made by hand on *System → Remote access* with the scopes `rpc:configure`
and `meta:read` can be entered in the *Token* field. Pairing is the simpler way: it also pins the system's
certificate, which a token entered by hand needs as well unless Node.js trusts that certificate.

**What stays** (checked by converting a classic HmIP-RF instance with history settings, an alias and a room on its
objects):

- every object id, with its type, role and data type: devices, channels and datapoints are created the same way as
  with a CCU;
- the custom settings on the states (history, InfluxDB, SQL and the like), so the recorded history carries on;
- aliases and scripts that use the ids, and visualisations;
- the values: the instance writes the values the system holds into the states when it connects.

**What changes:**

- with the names option on, the names: devices and channels are named as on the system, datapoints
  `<channel name>.<DATAPOINT>` (as hm-rega named them); a device without a name on the system keeps its address;
- the rooms and functions of the instance's objects (next section);
- *Synchronize objects (once)* is not needed any more: the system sends its device list each time the instance
  connects, and a device paired later arrives by itself.

## Rooms and functions

**With *Take names, rooms and functions from the system* on, the system decides the rooms and functions of the
instance's objects.** hm-rpc creates an enum for each room and function of the system and keeps their members in step,
live, whenever something changes on the system:

- the enum ids come from the system's taxonomy, such as `enum.rooms.wohnzimmer`; a room taken over from the CCU's
  built-in ones may keep its internal name, such as `enum.rooms.roomgarage` (shown as *Garage*). A room inside a room
  becomes an enum of its own, named by its path (`eg/wohnzimmer` → `enum.rooms.eg_wohnzimmer`);
- **the instance's objects are removed from every other room and function enum**, including the ones hm-rega created
  and the ones you made yourself in ioBroker. Members of other adapters stay;
- so rooms and functions of Homematic devices are maintained on the system from now on: in its *Control* view, or in
  [Homematic Manager](https://github.com/hobbyquaker/homematic-manager). The change reaches ioBroker at once.

**hm-rega's enums** keep their ids (`enum.rooms.<name as in the CCU>`, for the built-in rooms the English word, such as
`enum.rooms.Kitchen`), but lose their Homematic members, and the same room appears twice in ioBroker, once empty.
Check whether a script or a visualisation uses such an enum id (a selector by room *name* keeps working when the name is
the same), then delete the empty ones under *Objects* or *Categories*.

**If you want to keep maintaining names and rooms in ioBroker,** untick the option before pairing. hm-rpc then leaves
names, rooms and functions alone: the names hm-rega gave stay, and new devices are named by their address.

When an instance is deleted, the enums it created stay behind, empty; delete them by hand.

## Step 3: remove hm-rega and CUxD

- **hm-rega:** delete its instance (*Instances*, the bin icon). Its objects go with it: the system variables and
  programs under `hm-rega.<n>`. Scripts that read or set them need a new home first.
- **CUxD:** delete its hm-rpc instance.

| On the CCU (hm-rega) | On openccu-lite with ioBroker |
| --- | --- |
| names of devices, channels and datapoints | hm-rpc's names option (above) |
| rooms and functions | hm-rpc's names option; maintained on the system |
| system variables | states of your own in ioBroker (`0_userdata.0`) |
| programs and ReGa scripts | ioBroker scripts (the JavaScript or Blockly adapter), or Node-RED (on the system as [RedMatic](https://github.com/rdmtc/RedMatic), or in ioBroker) |
| favourites | not carried over; your visualisation's own views |
| CUxD devices | no replacement on openccu-lite; their task goes to ioBroker adapters of their own |
| the CCU's service messages (UNREACH, LOWBAT, CONFIG_PENDING) | the datapoints on channel 0 of each device, as before |

[porting-from-rega.md](porting-from-rega.md) maps the ReGa's calls to what replaces them on openccu-lite, for scripts
that talked to the CCU directly.

## A new ioBroker, or another interface

- **With discovery** (5.4.0 or later): a scan finds openccu-lite by its open version answer and proposes **one hm-rpc
  instance per interface** the system runs, in openccu-lite mode, never hm-rega or a classic instance. An interface an
  existing instance already covers for the same address (a classic or an openccu-lite one) is not proposed again. Open
  each new instance's settings afterwards and pair it (step 2, from *Pair*). **Discovery scans only the network
  ioBroker is in:** a system in another subnet is not found.
- **By hand:** add an hm-rpc instance per interface under *Adapters*, then set it up as in step 2.

## Pairing new devices

hm-rpc does not pair devices. Pair them with [Homematic Manager](https://github.com/hobbyquaker/homematic-manager) (an
addon on the system, or a desktop application) or another program that manages devices, such as
[OpenCCU-Loom](https://github.com/SukramJ/openccu-loom). The new device's objects appear in ioBroker by themselves,
with its name and rooms once they are set on the system. Mind the first limit below while it applies to your version.

## Known limits

- **hm-rpc 4.3.0: a device paired later deletes the objects of the instance's other devices.** The objects come back
  at the next start of the instance, but the settings made on them, such as history recording, are lost. Fixed in
  versions after 4.3.0. Until you have such a version, tick **Don't delete devices**
  under *Additional settings* before pairing a device. Objects of devices removed on the system then stay in ioBroker;
  delete them by hand.
- **Discovery finds systems in its own subnet only;** add an instance by hand for a system elsewhere.
- **No ReGa:** hm-rega, CUxD, system variables, programs and HM-Script are gone for good (see step 3).
- **hm-rpc older than 4.3.0** has no daemon *openccu-lite*; check the version before converting (see
  [Before you start](#before-you-start)).
