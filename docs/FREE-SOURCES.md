# Free sources catalog — movies, subtitles, addons

Research catalog: legal free content sources found on GitHub/GitLab/web
(FMHY, Stremio addon ecosystem, subtitle services, FAST providers, public
domain archives). Slovenian annotations; status-checked 2026-11-12/13.
Nothing here is auto-installed — sources marked "omogočen" are enabled in
the app, everything else is saved for future connector development.

# 📚 KATALOG BREZPLAČNIH VIROV — filmi, podnapisi, dodatki
*Zbrano 13.11.2026 — samo naslovi/navodila, nič ni nameščeno. Opal: 45 iskalnikov + 10 Live TV virov že deluje.*

---

## 1. PODNAPISI
| Vir | URL | Stanje | Opomba |
|---|---|---|---|
| **Podnapisi.net** | https://www.podnapisi.net | živ (skriptni dostop blokiran v tem omrežju) | **največja baza, odlična slovenska pokritost**; ima tudi API za razvijalce |
| **Titlovi.com** | https://www.titlovi.com | ✅ 301→živ | slovensko/hrvaško območje, SI podnapisi |
| **OpenSubtitles.com** | https://www.opensubtitles.com | ✅ 307/403 (zahteva API ključ — brezplačen) | v aplikaciji že omogočen (opensubtitles.json) |
| OpenSubtitles.org | https://www.opensubtitles.org | ✅ 307 | klasična stran |
| SubDL | https://subdl.com | živ | večjezični, dober za SI |
| YIFY Subtitles | https://yifysubtitles.me | živ | za YTS izdaje |
| Addic7ed | https://addic7ed.com | živ | TV serije (EN), hitri izpusti |
| Subscene | subscene.com | ❌ mrtev od 2023 | ne uporabljaj |

**Integracijski potencial za Opal:** Podnapisi.net + Titlovi.com kot dodatna podnapisna vira (razvojno: podobno kot opensubtitles connector).

## 2. FILMI — BREZPLAČNI LEGALNI VOD
| Servis | URL | Stanje | Kaj ponuja |
|---|---|---|---|
| **RaiPlay** | https://www.raiplay.it | ✅ 200 | **10.000+ naslovov** (filmi, serije, dokumentarci) — italijansko, brezplačno z oglasi |
| **ARTE.tv** | https://www.arte.tv | ✅ 301 | francosko/nemško — vrhunski dokumentarci + arthouse filmi |
| **RTV SLO (4d)** | https://4d.rtvslo.si | ✅ 301 | **slovenski arhiv** (oddaje, filmi) — potrebna SI registracija |
| RTVE (Španija) | https://www.rtve.es | ✅ 200 | javna španska vsebina |
| ZDF Mediathek | https://www.zdf.de | ✅ 200 | nemška javna vsebina |
| Tubi | https://tubitv.com | ✅ 302 | 50.000+ naslovov (US, z oglasi) — v Opalu že LIVE TV, VOD bi zahteval konektor |
| Crackle | https://www.crackle.com | ❌ 000 (geo) | US-only |
| **Archive.org** | https://archive.org | ✅ nativno v Opalu | javna domena + Creative Commons (milijoni) |
| **YouTube — filmski kanali** | glej spisek | ✅ nativno (iskanje po YouTube) | Popcornflix, Mosfilm, PizzaFlix, Paramount Vault, Timeless Classic Movies, CultCrash, Feature Film Channel — išči po imenu kanala + naslovu |
| Kanopy / Hoopla | kanopy.com / hoopladigital.com | z bibliotečno kartico | US/KAN — kvalitetna kinoteka |

## 3. STREMIO DODATKI (legalni — stanje v Opalu)
| Dodatek | Status v Opalu |
|---|---|
| Public Domain Movies (publicdomainmovies.now.sh) | ✅ omogočen |
| Internet Archive | ✅ nativen |
| YouTube | ✅ omogočen |
| OpenSubtitles | ✅ omogočen |
| WatchHub (kje je naslov legalno) | ✅ omogočen |
| TMDB (metapodatki) | ✅ omogočen |
| Trakt (sinhronizacija) | ✅ omogočen |
| Cine.ar (argentinska javna) | regionalno, ne dodano |
| Twitch | živ, zahteva OAuth — ne dodano |

## 4. LIVE TV / FAST — trenutno stanje
- 10 virov nameščenih, **35.637 kanalov** v katalogu (audit 12.11.2026: vsi živi)
- Fast generator prostor izčrpan: BuddyChewChew (5 servisov) = edini aktivni
- Rakuten generator mrtev; Xumo/DistroTV/LocalNow/Stirr ni živih generatorjev
- TDTChannels (573 ES/PT) ingest blokiran s strani strežnika — poskusiti znova kasneje

## 5. EPG (elektronski program) — za prihodnji razvoj
| Vir | URL | Opomba |
|---|---|---|
| iptv-org/epg | https://github.com/iptv-org/epg | XMLTV vodniki po državah (SI: epg_ripper_SI? — HR/BA/RS obstajajo) |
| epgshare01 | https://epgshare01.online | XMLTV za stoje virov (uporablja ga ExYU seznam) |
| Opal EPG podpora | — | **aplikacija še nima EPG** — razvojni predlog za upstream |

## 6. ORODJA, KI SO JIH DRUGI NAREDILI (navdih)
| Projekt | URL | Opomba |
|---|---|---|
| BuddyChewChew/app-m3u-generator | github.com/BuddyChewChew/app-m3u-generator | FAST m3u generator (GitHub Actions) — že vgrajen |
| cabernetwork/cabernet | github.com/cabernetwork/cabernet | WFA→HLS pretvornik (US paid TV) |
| akiralereal/iptv | github.com/akiralereal/iptv | kitajski self-hosted agregator |
| Movies Deluxe | r/SideProject post | 25.000 PD filmov — značka Archive.org+YouTube (Opal to že doseže) |
| iptv-org/epg | github.com/iptv-org/epg | glej §5 |

## 7. NE-VKLJUČENO (piratsko) — že v aplikaciji kot iskalniki, brez dodatnega beleženja
YTS, EZTV, 1337x, TPB, Nyaa, LimeTorrents, TorrentGalaxy, Knaben, SolidTorrents, TheRARBG, TorrentProject, UIndex, TorrentFunk, TorrentDownloads, IlCorsaroNero, bitsearch, Glotorrents, Rutor, TokyoTosho, dmhy, mikan … (45 skupaj)

## 8. FMHY (Free Media Heck Yeah) — dodatni legalni filmski sajtovi (brskalnik)
*Vir: fmhy.net/video — vsi preverjeni živi 13.11.2026. To so spletne strani (gledanje v brskalniku), Opal jih ne more direktno predvajati brez konektorjev.*

### Javna domena / klasika / arhivi
| Sajt | URL | Opomba |
|---|---|---|
| Cinetimes | https://cinetimes.org | ✅ evropska klasika |
| RetroFlix | https://retroflix.org | ✅ klasični filmi |
| The Classic Movies | https://www.the-classic-movies.com | ✅ |
| moonflix | https://moonflix.com | ✅ restavrirana klasika |
| RareFilmm | https://rarefilmm.com | ✅ redki filmi |
| Silent Hall of Fame | https://silent-hall-of-fame.org | nemih filmov |
| Danish Silent Film | https://www.stumfilm.dk | danski nemih filmov |
| National Film Board (Kanada) | https://www.nfb.ca | ✅ ogromen brezplačen arhiv |
| Prelinger Archives | https://archive.org/details/prelinger | (v Opalu prek IA) |
| European Film Gateway | https://www.europeanfilmgateway.eu | evropski filmski arhivi |
| BFI Player (free del) | https://player.bfi.org.uk/free | UK IP |

### Free z oglasi (niso v Opalu — brskalnik)
| Sajt | URL | Opomba |
|---|---|---|
| Filmzie | https://filmzie.com | ✅ indie + klasika |
| Shout! TV | https://shout-tv.com | ✅ kult filmi/serije |
| Fawesome | https://fawesome.tv | |
| Playary | https://playary.com | |
| BYUtv / Found TV / DarkRoom | byutv.org / watch.foundtv.com / darkroom.film | US |
| Xumo Play | https://play.xumo.com | (v Opalu Xumo ni — ni konektorja) |
| Red Bull TV | https://www.redbull.tv | šport + adrenalinske |
| JustWatch | https://www.justwatch.com | iskalnik kje je film legalno |

### Podnapise API (za prihodnji razvoj)
| Vir | URL | Opomba |
|---|---|---|
| **Wyzie Subs** | https://sub.wyzie.io | subtitle-scraping API (Stremio/Nuvio ekosistem) — kandidat za Opal konektor |
