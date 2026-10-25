# 05 — Naming the project

Project: free/OSS macOS app plus an Android companion that gives Android phones an "iPhone Mirroring"-style
experience on the Mac (screen mirroring, control from the Mac, phone apps as Mac windows, notifications,
clipboard, file drop). Repo owner: `SaidulBadhon`. Research date: 2026-10-25.

## Method, and what it can and can't tell you

- **GitHub:** `gh search repos <name> --sort stars --limit 6..8` for each candidate, then combined queries
  (`"<name> android"`, `"<name> mirror"`, `"<name> phone"`) for the finalists. Star counts are as of 2026-10-25.
  The search API is limited to 30 requests a minute. I hit that limit once and re-ran the affected names
  with a delay, so every name in the tables below did get a search.
- **Web, app stores and companies:** WebSearch queries for "<name> app", "<name> Mac/Android", and "<name> trademark".
- **Domains:** `dig NS/A` plus `curl` on `https://<name>.app` and `https://<name>.dev`, reading the page title.
  Seeing NS records means the domain is registered. A page title tells you what is running there, if anything.
- **Trademark registers: NOT verified.** USPTO tmsearch rejected a scripted POST with HTTP 405. Justia
  Trademarks and uspto.report returned a Cloudflare challenge or HTTP 403. The trademark notes below therefore
  come only from web search. Before you commit to a name, run a manual search on tmsearch.uspto.gov and EUIPO
  eSearch in classes 9 and 42.

## 1. Candidate pool (50 names)

Seeds (19): Porthole, Bifrost, Ferry, Pontoon, Isthmus, Lagrange, Tether, Trestle, Halo, Pane, Prism, Twin,
Kinship, Rapport, Overpass, Lumen, Facet, Orbit, Mirra.

My additions (31): **Tombolo**, **Tidelock**, **Bascule**, **Barycenter**, **Gangway**, **Fenestra**, Oriel,
Transom, Causeway, Cupola, Shoji, Ponte, Cradle, Berth, Hyphen, Vitrine, Skylight, Lanyard, Gondola, Mullion,
Perch, Airlock, Locket, Coracle, Spyglass, Jetty, Mooring, Yoke, Inlet, Bezel, Outrigger
(plus quick-kills that were never searched: Hashi, Quay, Portal, Wormhole, Janus, Shadow, Periscope, Rendezvous,
Magnet, Tidal, Gemini, Nexus, Duo, Tango, Echo, Hatch, Keyhole).

## 2. Eliminations

### Trademark or implied-Apple/Google/Microsoft problems
| Name | Reason |
|---|---|
| Rapport | `rapportd` / Rapport.framework is Apple's private daemon behind Continuity and Handoff, so the name would imply Apple ([MacKeeper explainer](https://mackeeper.com/blog/what-is-rapportd-on-mac/), [VitalsMac](https://vitalsmac.com/glossary/rapportd)). |
| Halo | Microsoft's *Halo* trademark. Also [halo-dev/halo](https://github.com/halo-dev/halo) has 40k stars. |
| Bifrost | Autodesk sells **Bifrost for Maya** ([autodesk.com](https://www.autodesk.com/products/maya/bifrost)). [maximhq/bifrost](https://github.com/maximhq/bifrost) has 9.1k stars. **[zacharee/Bifrost](https://github.com/zacharee/Bifrost)** (1.6k stars) is a Samsung phone-firmware tool, which sits right next to this project. Very crowded. |
| Rendezvous, Magnet, Hashi, Gemini, Nexus, Duo, Lyra, Keyhole, Portal, Shadow, Periscope, Tidal, Echo | Respectively: Apple's old name for Bonjour; the Magnet Mac window manager; HashiCorp; Google; Google; Google; Google codec; Google Earth's ancestor; Meta Portal; Shadow cloud PC (remote desktop); Twitter/Periscope; Tidal music; Amazon. |

### Collision in this same space (phone and desktop, mirroring, remote access, file transfer, Mac windowing)
| Name | Evidence |
|---|---|
| Tether | [zackb/tether](https://github.com/zackb/tether), 1.5k stars: "Linux + iPhone Continuity / iMessage / SMS". That is a direct hit. Tether (USDT) is also a large trademark, and "tethering" is a stock Android feature. |
| Ferry | Three phone↔computer file-transfer OSS projects use it: [lenajeremy/ferry](https://github.com/lenajeremy/ferry) ("AirDrop for Windows, Linux and Android", with Mac and Android apps), [sholajegede/ferry](https://github.com/sholajegede/ferry), [itai-gendler/ferry](https://github.com/itai-gendler/ferry). |
| Bezel | Nonstrict's **Bezel**, a paid Mac app that mirrors an iPhone onto the Mac ([nonstrict.eu/bezel](https://nonstrict.eu/bezel/)). This is a direct competitor. |
| Porthole | Danger Cove's **Porthole** Mac app (AirPlay audio streaming, discontinued) ([dangercove.com/porthole](https://www.dangercove.com/porthole/)). **Dataplicity Porthole** forwards ports from remote devices for RDP/VNC/file transfer and has a macOS client ([downloads.dataplicity.com/porthole/macos](https://downloads.dataplicity.com/porthole/macos/)). **[porthole.dev](https://www.porthole.dev/)** is a localhost tunnel. [SeStudio/porthole](https://github.com/SeStudio/porthole) does port sharing. Rated medium-high. |
| Transom | [aydinmrnv/transom](https://github.com/aydinmrnv/transom): "seamless remote app windows from macOS to Windows". Tiny (5 stars) and pushed 2026-10-20, but it is exactly the "apps as windows" concept. |
| Oriel | 8+ macOS apps on GitHub use it, including a window switcher ([jamesofficer/oriel](https://github.com/jamesofficer/oriel)), notch apps ([Slybald/oriel](https://github.com/Slybald/oriel), [Kkray19/Oriel-releases](https://github.com/Kkray19/Oriel-releases)), a file manager ([tosiabunio/Oriel](https://github.com/tosiabunio/Oriel)) and getoriel.dev ([khanhld2109/oriel-releases](https://github.com/khanhld2109/oriel-releases)). There is also an [App Store listing](https://apps.apple.com/ng/app/oriel/id6754066224). It's a nice word, but the Mac namespace is saturated. |
| Shoji | Two separate Mac window managers are called Shoji ([shojimac.com](https://shojimac.com/), [getshoji.com](https://getshoji.com/)), plus a Mac privacy-screen app. |
| Ponte | **Surge Ponte** creates a private network between Mac and iOS devices ([Surge KB](https://kb.nssurge.com/surge-knowledge-base/zh/guidelines/ponte)). |
| Inlet | **inlets** is a tunneling product ([inlets/inlets-pro](https://github.com/inlets/inlets-pro), 1.4k-star operator). |
| Yoke | [rmst/yoke-android](https://github.com/rmst/yoke-android) / [F-Droid](https://f-droid.org/en/packages/com.simonramstedt.yoke/) turns an Android phone into a network gamepad for a computer. SkyYoke is a phone-as-controller app. |
| Cradle | [BAAI-Agents/Cradle](https://github.com/BAAI-Agents/Cradle) (2.6k stars) is "General Computer Control", which is close to remote control. |
| Mullion | [dttdrv/mullion](https://github.com/dttdrv/mullion) (D3D-on-Metal for Mac), a Win32 window host, and a Windows Terminal fork all use it. Windowing-adjacent and crowded. |
| Cupola | A brand-new Mac notch app [trycupola.com](https://trycupola.com/) and an Android ISS wallpaper [IT-BAER/cupola-android](https://github.com/IT-BAER/cupola-android). |
| Skylight | Skylight Calendar is a consumer Android photo-frame device ([wesbos/photo-frame-dashboard](https://github.com/wesbos/photo-frame-dashboard) mentions it). Skylight is also a Rails APM. |
| Mirra | **Seagate Mirra** was a file-sharing/backup "personal server" with a Mac client ([Seagate guide](https://www.seagate.com/content/dam/seagate/migrated-assets/support/disc/manuals/mirra/Getting_Started_Guide_for_Macintosh_21.pdf)). It's discontinued, but it was in the file-sharing space. It also reads as a near-twin of "Mirroid", which is on the avoid list. |
| Locket | Locket Widget is a very large photo-sharing phone app (GitHub mod repos reference it). |
| Lagrange | [skyjake/lagrange](https://github.com/skyjake/lagrange) (1.5k stars) is a polished Gemini browser shipped on macOS and Android. That's the same stores and the same audience. |

### Too crowded, too generic, or hard to say
| Name | Reason |
|---|---|
| Pontoon | [mozilla/pontoon](https://github.com/mozilla/pontoon) is Mozilla's flagship localization platform (1.7k stars). |
| Causeway | **Apache Causeway™** ([apache/causeway](https://github.com/apache/causeway), 907 stars). ASF actively polices its marks. Also the CauseWay DOS extender. |
| Isthmus | The "sthm" cluster is hard to pronounce and to spell. |
| Prism, Lumen, Orbit, Facet, Twin, Pane, Overpass, Kinship | Each has several notable projects: PrismJS 13k, PrismLauncher 11k, Laravel Lumen 7.5k, Lumen Technologies (a telecom), google/orbit 4k, facet-rs 2.6k, twin.macro 8k, Overpass font and OSM Overpass API, Kinship (Mars Petcare). Generic words with no ownable identity. |
| Trestle | [TrestleAdmin/trestle](https://github.com/TrestleAdmin/trestle) has 2k stars. There's also IBM's compliance-trestle, CoreLogic Trestle (real estate), Trestle networking, sudoku, and HOA apps ([App Store](https://apps.apple.com/us/app/trestle-the-new-sudoku/id1300230302), [trestle-network](https://trestle-network.web.app/)). trestle.app is parked at Afternic. Medium overall. Nothing collides in this space, but the name is busy. |
| Gangway | No collision in this space (closest is a [VS Code SFTP extension](https://open-vsx.org/extension/ddtcorex/gangway) and the archived [vmware gangway](https://github.com/vmware-archive/gangway)). But at least three maritime apps use the name: **gangway.app**, a seafarer social network (title verified by curl); [Performing Nerd's Gangway](https://www.performingnerd.com/gangway) for cruise crew; and [Gangway Technologies™](https://www.gangwaytech.com/). Medium, so it's a runner-up only. |
| Fenestra | Latin for "window", which is a lovely meaning. But [Fenestra+](https://apps.apple.com/us/app/fenestra-for-pvc-aluminium/id1585846240) is already an iOS/Mac App Store app, along with [Fenestra 2000](http://www.fenestra2000.com/en/), [fenestra.app](https://www.fenestra.app/), and [WerWolv/Fenestra](https://github.com/WerWolv/Fenestra) (an ImGui UI system from the ImHex author, 137 stars). Medium. Runner-up. |
| Berth, Lanyard, Gondola, Perch, Airlock, Spyglass, Jetty, Mooring, Coracle, Vitrine, Hyphen, Outrigger, Lintel, Sash, Dormer, Casement, Funicular | Each is either crowded (Eclipse Jetty, Discord Lanyard 1.5k, Spyglass 2.7k, the Coracle nostr client, Berth SSH for Mac, airlock ×5) or weak and obscure for an app name. |

## 3. Detailed checks on the finalists

### Tombolo — *a sandbar that ties an island to the mainland*
- **GitHub:** the top results are [ConnectedPlacesCatapult/TomboloDigitalConnector](https://github.com/ConnectedPlacesCatapult/TomboloDigitalConnector) (59 stars, a UK urban-data tool, last pushed 2026-02) and [hpcc-systems/Tombolo](https://github.com/hpcc-systems/Tombolo) (9 stars, the LexisNexis Risk Solutions data-catalog tool for HPCC Systems, [summit talk](https://www.youtube.com/watch?v=56Qr0OtC2sc)). `"tombolo phone"` returned 0 results. Neither project is in connectivity or mirroring.
- **Apps and companies:** [tomboloapp.com](https://tomboloapp.com) is live (curl title: "Tombolo - The Productivity Platform For Freelancers"). It's a small Israeli project-management SaaS ([Crunchbase](https://www.crunchbase.com/organization/tombolo-8648), [X @tomboloapp](https://x.com/tomboloapp), 22 IG followers). There's also an Android giveaway browser `com.blogspot.guaitxop.tombolo` (50+ installs, last updated 2018, [APKCombo](https://apkcombo.com/tombolo/com.blogspot.guaitxop.tombolo/)). No Mac App Store or Play Store app in this space turned up.
- **Near-homophone:** Tombola, the UK bingo brand ([Wikipedia](https://en.wikipedia.org/wiki/Tombola_(bingo_company))), and a number of "Tombola" raffle apps. It's a different word in a different field, but the similarity is worth knowing.
- **Trademark:** web search found no TOMBOLO mark in software. The register itself was not checked (see Method).
- **Domains:** `tombolo.app` is registered: Vercel NS, and curl returned `404 DEPLOYMENT_NOT_FOUND`, so nothing is served. `tombolo.dev` is registered: Cloudflare NS, empty response. Neither is free. `tombolo.com` didn't respond. You'd use the github.io site, or a variant such as `tombolo.sh` or `gettombolo.app`, which I did not check.
- **GitHub namespace:** `github.com/tombolo` is a personal account (Joseph Mumo, 55 repos, none related). `SaidulBadhon/tombolo` returns 404, so the slug is available under your account.
- **Fit:** 7 letters, 3 syllables, spelled the way it sounds (TOM-buh-low). The metaphor fits precisely: the phone is the island, the Mac is the mainland, and a tombolo is the natural strip that joins them. Downsides: it isn't a natural verb, and "tomb" is in the first syllable.

### Tidelock — *tidal locking (a moon that always faces its planet), and also a canal tide-lock (the passage between two bodies of water)*
- **GitHub:** only tiny repos turned up: [RoryBarnes/TideLock](https://github.com/RoryBarnes/TideLock) (an exoplanet paper), [xoloteach/TIDELOCK](https://github.com/xoloteach/TIDELOCK) (a game), and a few with 0–1 stars. `"tidelock mirror"` returned 0 results.
- **Apps and companies:** Madvox **TideLock** is a Solar System and Moon astronomy app for Windows and Android ([MS Store](https://apps.microsoft.com/detail/9nblggh1p7rm), [APKCombo](https://apkcombo.com/tidelock/io.cordova.myappd04bdc/), Android build last updated 2018, [Madvox](https://www.madvox.com/legacy/)). [Tidelock Systems](https://tidelocksystems.com/) builds custom AI software for small businesses (DC area). [TideLock Partners](https://pitchbook.com/profiles/advisor/741466-99) is an M&A advisory firm. [tidelock.tech](https://www.tidelock.tech/) does Solana token-locking. tidelock.us is a fishing platform. None of them is in connectivity, but there are two US software/finance businesses using the name.
- **Domains:** both are registered. `tidelock.app` serves "OrionRider" (a space/globe site). `tidelock.dev` returns Cloudflare error 526.
- **Fit:** 8 letters, modern, easy to say. Tagline: "Your phone, tidally locked to your Mac." Downside: "lock" can make it sound like an app-lock or security tool.

### Bascule — *a bascule bridge, the counterweighted drawbridge*
- **GitHub:** there's no notable repo with the exact name. Most hits are French uses of "bascule" (to toggle). There's also [xmidt-org/bascule](https://github.com/xmidt-org/bascule) (2 stars, an auth library in Comcast's XMiDT device-messaging stack). `"bascule android"` returned 0 results.
- **Apps and companies:** **Cubist's "Bascule Drawbridge"** is a security layer for blockchain bridges, used by Lombard for LBTC ([cubist.dev](https://cubist.dev/products/bascule-drawbridge), [Lombard docs](https://docs.lombard.finance/technical-documentation/protocol-architecture/bascule-drawbridge)). That's a software product with the same "bridge" story, though in crypto rather than device connectivity. No Mac or Android app named Bascule turned up.
- **Domains:** both are registered. `bascule.app` serves "Bascule Data". `bascule.dev` has Cloudflare NS and no site.
- **Fit:** 7 letters, 2 syllables, and an elegant metaphor: the bridge lowers to connect and lifts to disconnect, which suits a privacy-first, local-only tool. Downside: pronunciation is ambiguous (BASS-kyool vs. bas-KOOL), so you'd need to teach it.

### Barycenter — *the shared center that two bodies orbit*
- GitHub has only math and optimal-transport repos (the top one is 275 stars, an image-restoration paper). Web search found no app or product with the name. Collision-wise it's the cleanest name here.
- At 10 characters and 4 syllables it's at the length limit, and it feels clinical and mathematical. I kept it as a runner-up.

## 4. Final ranking

### 1. Tombolo — recommended
- **Tagline:** "The sandbar between your phone and your Mac."
- **Metaphor:** a tombolo is a natural land bridge that joins an island (your phone) to the mainland (your Mac). The bridge metaphor is built in, and it's distinctive without being a cliché.
- **Collisions:** none in this space. The nearest are minor and in other fields: Tombolo Ltd's freelancer PM SaaS, the HPCC Systems/LexisNexis data-catalog OSS, a 2018 Android giveaway app with 50+ installs, and the Tombola bingo near-homophone. Links are in §3.
- **Risk: LOW.** That rating depends on a manual USPTO/EUIPO check in classes 9 and 42, which I haven't done.
- **Repo slug:** `SaidulBadhon/tombolo` (verified available: 404).
- **Android package:** `io.github.saidulbadhon.tombolo`. Don't use `dev.tombolo.*`, because tombolo.dev belongs to someone else.
- **macOS bundle id:** `io.github.saidulbadhon.Tombolo`

### 2. Tidelock
- **Tagline:** "Your phone, tidally locked to your Mac."
- **Metaphor:** orbit. The phone always faces the Mac, the way the Moon always faces Earth. It also works as a tide-lock, the passage between two waters.
- **Collisions:** none in this space. Madvox TideLock (a stale astronomy app), Tidelock Systems (AI consultancy), TideLock Partners (M&A), and tidelock.tech (Solana) are all in §3.
- **Risk: LOW–MEDIUM.** Several active businesses use the name, and "lock" suggests security.
- **Repo slug:** `SaidulBadhon/tidelock` (verified available: 404).
- **Android package:** `io.github.saidulbadhon.tidelock`
- **macOS bundle id:** `io.github.saidulbadhon.Tidelock`

### 3. Bascule
- **Tagline:** "Lower the bridge to your phone."
- **Metaphor:** a drawbridge. It connects when lowered and disconnects when raised, which is a natural fit for privacy and pairing.
- **Collisions:** none in this space. Cubist's "Bascule Drawbridge" (crypto bridge security), a tiny XMiDT auth library, and the bascule.app "Bascule Data" site are all in §3.
- **Risk: LOW–MEDIUM.** The collisions are minor. The bigger cost is pronunciation and the fact that few people know the word.
- **Repo slug:** `SaidulBadhon/bascule` (verified available: 404).
- **Android package:** `io.github.saidulbadhon.bascule`
- **macOS bundle id:** `io.github.saidulbadhon.Bascule`

**Runners-up:** Barycenter (clean but long and clinical), Gangway (easy to say, but crowded in maritime apps),
Fenestra (a great meaning, but crowded in physical-window software and Fenestra+ is on the App Store).

## 5. Before locking the name (not done here)
1. Manual search for the exact mark and close variants (TOMBOLO, TOMBOLA) on tmsearch.uspto.gov, EUIPO eSearch,
   and WIPO Global Brand Database, in classes 9 and 42.
2. Search Play Console and App Store Connect for the exact display name when you create the listings.
3. Pick a website domain. Both `.app` and `.dev` are taken for all three finalists, so check variants
   (`get<name>.app`, `<name>.sh`) or use `saidulbadhon.github.io/<name>`.
4. In marketing copy, refer to "Android" and "Mac" only descriptively ("for Mac", "works with Android phones").
   Keep them out of the name, the icon, and the logo.
