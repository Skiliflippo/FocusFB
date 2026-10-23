# Guida Completa: Come generare e installare FocusFB su iOS 26.6+ (SideStore, Feather, LiveContainer)

## Di cosa hai bisogno? (In breve)

Poiché l'app ufficiale di Facebook è proprietaria di Meta e protetta da DRM FairPlay (esattamente come avviene per **Glow** e **Flow**, nessuno può ridistribuire legalmente l'IPA originale già pacchettizzata) e la compilazione per iOS richiede l'SDK Apple su macOS, ti servono **solo 2 cose gratuite**:

1. **Un account GitHub gratuito** (userà i runner `macos-latest` gratuiti di GitHub Actions per compilare per te sia `FocusFB.dylib` sia la `.ipa` già patchata, **senza bisogno di avere un Mac**).
2. **Una `.ipa` decrittata pulita dell'ultima versione di Facebook** (es. v575–580+, senza altri tweak pre-iniettati), esattamente come quella che useresti per fare la build di Glow.

---

## Passo 1 — Carica il progetto sul tuo GitHub

1. Accedi a [github.com](https://github.com) e crea un nuovo repository (es. `FocusFB` — se lo imposti **Public**, i minuti macOS di GitHub Actions sono gratuiti e illimitati; il workflow salva i file come *Artifacts* o *Draft Release*, quindi la tua IPA non diventa pubblica a meno che tu non decida di pubblicare la release).
2. Carica tutti i file contenuti nella cartella `FocusFB` (oppure estrai `FocusFB-repo.zip` e fai push con Git), assicurandoti che la cartella `.github/workflows/build.yml` sia presente.
3. Appena caricato il codice, vai nella scheda **Actions** del tuo repository: vedrai partire in automatico la prima build che in **~45 secondi** compila e verifica **`FocusFB.dylib`** e **`com.focusfb.tweak_1.0.0_iphoneos-arm64.deb`**!

---

## Passo 2 — Scegli il metodo più comodo per te

Hai **3 strade**, tutte supportate dallo stesso progetto:

### Opzione A: Iniezione diretta sul telefono con Feather (Velocissima, zero upload dell'IPA!)
Se usi **Feather**, non devi nemmeno caricare l'IPA di Facebook sul cloud:
1. Nella scheda **Actions** del tuo repo GitHub, apri l'ultima esecuzione completata e scarica **`FocusFB-Build-Output`** (contiene `FocusFB.dylib`).
2. Salva `FocusFB.dylib` nell'app **File** del tuo iPhone.
3. Apri **Feather** → scheda **Library** → importa la tua `.ipa` decrittata pulita di Facebook.
4. Tocca l'app appena importata → **Sign / Modify** → **Inject Dylibs / Tweaks** → aggiungi **`FocusFB.dylib`**.
   - *(Opzionale)* Puoi cambiare il **Nome App** in `Marketplace` così sulla Home avrai direttamente l'icona dedicata!
5. Firma e installa.

---

### Opzione B: Uso modulare dentro LiveContainer (via SideStore o Feather)
`FocusFB.dylib` è compilata con `library.mk` **senza alcuna dipendenza da CydiaSubstrate o ElleKit**:
1. Scarica `FocusFB.dylib` dagli *Artifacts* di GitHub Actions sul tuo iPhone.
2. Apri **LiveContainer**, installa dentro LiveContainer la `.ipa` decrittata pulita di Facebook.
3. Copia `FocusFB.dylib` nella cartella **Tweaks** di LiveContainer e attivala nelle impostazioni del container di Facebook.
4. Avvia Facebook da LiveContainer: partirà direttamente in modalità **Solo Marketplace**!

---

### Opzione C: Generare la `.ipa` completa già patchata tramite GitHub Actions (Ideale per SideStore!)
Esattamente come funziona il builder di **Glow**:
1. Carica la tua `.ipa` decrittata pulita di Facebook su un servizio di file hosting temporaneo o cloud (supportati automaticamente: **Filebin.net**, **Dropbox**, **Google Drive** con condivisione *"Chiunque abbia il link"*, oppure un link diretto).
2. Nel tuo repository GitHub vai su **Actions** → seleziona a sinistra **Build FocusFB (IPA + Dylib + DEB)** → clicca **Run workflow** a destra.
3. Compila i campi:
   - **`ipa_url`**: incolla il link alla tua `.ipa` decrittata di Facebook.
   - **`display_name`**: lascia `Facebook` oppure scrivi `Marketplace` se vuoi che sull'iPhone si chiami così.
   - **`bundle_id`**:
     - Su **SideStore**: lascia `com.facebook.Facebook` (se hai disinstallato l'app Facebook dell'App Store, scelta consigliata per non sprecare slot!) oppure metti `com.facebook.Facebook.focus` se vuoi tenerle entrambe.
   - **`remove_extensions`**: lascia **`true`**! *(Fondamentale per **SideStore** con Apple ID gratuito: rimuove le 6+ estensioni inutili di Facebook così consumi **1 solo App ID** settimanale invece di 7!).*
4. Clicca **Run workflow** e attendi ~2 minuti.
5. Scarica **`FocusFB_Patched.ipa`** dalla sezione **Artifacts** dell'azione completata (oppure dalla bozza nella scheda **Releases**) e aprila direttamente in **SideStore** o **Feather**!

---

## Passo 3 — Come usare FocusFB una volta installata

1. **Al primo avvio**:
   - Effettua normalmente il login al tuo account Facebook (i fix Keychain e AppGroups per il sideloading sono già integrati dentro `FocusFB.dylib`).
   - Appena entrato, **FocusFB** attiva automaticamente il profilo **"Solo Marketplace"**:
     - Salta il News Feed e ti porta dritto sul **Marketplace**.
     - Nasconde dalla barra tutti gli altri tab (Home, Reels, Amici, Gruppi, Notifiche, Profilo, Menu), centrando in modo pulito l'icona del Marketplace.
     - Oscura il Feed Home e blocca qualsiasi apertura accidentale del player dei Reels.

2. **Come aprire il pannello Impostazioni di FocusFB quando vuoi modificare i tab**:
   - **Metodo 1**: **Tieni premuto (Long Press)** sull'icona **Marketplace** (o qualsiasi altro tab nella barra inferiore) → si apre il menu contestuale nativo iOS con **Impostazioni FocusFB**.
   - **Metodo 2**: **Tieni premuto** su un'area libera della barra di navigazione inferiore.
   - **Metodo 3 (Universale)**: **Tieni premuto con 2 dita per mezzo secondo** in qualunque punto dello schermo (funziona sempre, anche se attivi l'opzione *"Nascondi barra se c'è 1 solo tab"* per avere il Marketplace a tutto schermo!).

3. **E se in futuro Meta aggiorna Facebook (es. v590+) o aggiunge un nuovo tab?**
   - Puoi riusare la stessa `FocusFB.dylib` sulla nuova IPA!
   - In fondo alle **Impostazioni FocusFB** trovi la sezione **"Tab Rilevati in Questa Versione (Live)"**: mostra in tempo reale tutti i tab letti dall'app e ti permette di toccare qualsiasi nuovo tab futuro per impostare **Forza Nascondi** o **Forza Mostra** senza dover riscrivere una riga di codice.
