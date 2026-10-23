# FocusFB — Facebook senza distrazioni per iOS (Marketplace-Only & Tab Filter)

**FocusFB** è un tweak nativo iOS (`arm64`, zero dipendenze da `CydiaSubstrate` o `ElleKit`) progettato per l'ultima versione di **Facebook** (inclusa la nuova barra flottante `FBFloatingTabBar` introdotta su Facebook v575–580+ e la `FBTabBar` classica), installabile senza jailbreak su **iOS 15 – iOS 26.6+** tramite **SideStore**, **Feather** o **LiveContainer**.

Nasce per risolvere un problema concreto: aprire Facebook con un obiettivo preciso (ad esempio cercare o vendere un oggetto sul **Marketplace**) e ritrovarsi 20 minuti dopo intrappolati tra **Reels** e post algoritmici nel **News Feed**.

---

## Caratteristiche principali

- **Modalità "Solo Marketplace" attiva di default**: al primo avvio nasconde tutti i tab distraenti (Home, Reels/Watch, Amici, Gruppi, Notifiche, Profilo, Menu), lasciando visibile e centrato solo il **Marketplace**.
- **Selettore Tab granulare in tempo reale**: pannello impostazioni nativo iOS (`InsetGrouped`, in Italiano e Inglese) in cui decidere con singoli interruttori quali tab vedere sulla barra.
- **Avvio diretto sul Marketplace**: salta automaticamente il News Feed all'apertura dell'app (tramite attivazione nativa del tab + fallback in-process `fb://marketplace` che non rimbalza mai sull'app ufficiale).
- **Scudo Anti-Feed & Blocco Reels ovunque**:
  - Se il tab Home è disattivato, oscura il News Feed e mette in pausa eventuali video in autoplay nel caso Facebook tenti comunque di mostrarlo.
  - Blocca l'apertura a schermo intero del player verticale dei Reels/Watch anche cliccando link o suggerimenti.
  - Nasconde la barra delle Storie e i caroselli Reels inline.
- **Ispettore Live dei Tab**: elenca tutti i tab effettivamente presenti nella tua versione di Facebook con possibilità di forzare `Mostra` / `Nascondi` su singoli elementi futuri (es. nuovi tab sperimentali aggiunti da Meta).
- **Fix Sideloading integrati**: gestione automatica del Keychain (`accessGroup`), fallback `AppGroups` (`FakeGroupContainers`) e protezione crash entitlement Siri quando l'IPA è firmata con Apple ID gratuito (SideStore) o certificato di terze parti (Feather).

---

## Come aprire le Impostazioni FocusFB dentro l'app

1. **Pressione prolungata (Long Press)** sul tab **Marketplace** (o qualsiasi altro tab visibile) → apre il menu rapido nativo (*Impostazioni FocusFB*, *Vai a Marketplace*, *Solo Marketplace / Mostra Tutti*).
2. **Pressione prolungata** su un punto vuoto della barra inferiore di Facebook.
3. **Pressione prolungata con 2 dita (0,6 secondi)** in qualsiasi punto dello schermo (utile anche se scegli di nascondere l'intera barra inferiore!).

---

## Struttura del progetto

```text
FocusFB/
├── .github/workflows/build.yml        # Build automatica Cloud (macOS): genera .ipa, .dylib e .deb
├── src/
│   ├── Tweak.mm                       # Entrypoint constructor e rilevamento processo Facebook
│   ├── FocusFBPrefs.h / .mm           # Preferenze, preset, localizzazione IT/EN e registro tab live
│   ├── FocusFBSideloadFix.h / .mm     # Fix Keychain, AppGroups e Siri per SideStore/Feather/LiveContainer
│   ├── FocusFBTabManager.h / .mm      # Hook FBFloatingTabBar/FBTabBar, reflow tab, redirect Marketplace e scudi
│   └── FocusFBSettingsViewController.h / .mm  # Pannello impostazioni iOS nativo
├── scripts/
│   ├── verify_dylib.py                # Verifica automatica binario Mach-O arm64 e assenza Substrate
│   └── build_macos.sh                 # Script opzionale per compilazione locale su Mac
├── Makefile                           # Build Theos library.mk (arm64, iOS 15.0+)
└── GUIDA_COMPLETA_IT.md               # Istruzioni passo-passo per GitHub Actions, SideStore, Feather e LiveContainer
```

Consulta **[GUIDA_COMPLETA_IT.md](./GUIDA_COMPLETA_IT.md)** per tutti i passaggi dettagliati di compilazione cloud e installazione su iPhone.
