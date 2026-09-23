import Foundation

/// Le JavaScript que Caspr injecte dans la page ChatGPT, en chaînes.
///
/// Ici, dans `CasprCore`, parce que les tests l'atteignent : une faute de
/// syntaxe casse `swift test` (cf. `RelaisScriptsTests`). Dans la page, elle
/// ne se verrait pas — le script ne s'exécuterait simplement jamais, et rien
/// ne le dirait.
public enum RelaisScripts {

    /// L'écho : une copie du son que la page capte, pour Caspr.
    ///
    /// La page ChatGPT tient le micro pendant qu'elle écoute, et le micro que
    /// Caspr ouvrirait lui-même ne reçoit alors que du silence (mesuré : crête
    /// 0,072 avant, 0,000 après). On duplique donc le flux que la page a déjà
    /// obtenu, sans en ouvrir un second.
    ///
    /// Monde de la page, au début du document : il doit envelopper
    /// `getUserMedia` avant que chatgpt.com ne l'appelle, et seul ce monde voit
    /// la fonction que la page appelle.
    ///
    /// **Ce que ChatGPT reçoit n'en est pas touché.** Le Proxy rend la promesse
    /// d'origine, telle quelle ; le flux n'est ni cloné (un clone garderait le
    /// micro ouvert après l'arrêt), ni contraint, ni arrêté ; la copie passe
    /// par un gain nul, inaudible. Le prototype est remplacé, pas l'instance :
    /// aucune propriété nouvelle n'apparaît sur `navigator.mediaDevices`.
    ///
    /// `ScriptProcessor` et non `AudioWorklet` : la CSP de chatgpt.com refuse
    /// les modules `blob:` et `data:` (mesuré).
    ///
    /// Des **chaînes** seulement dans `detail` : un objet qui passe d'un monde
    /// à l'autre n'est pas garanti, une chaîne l'est. Le son en base64 d'Int16
    /// petit-boutiste ; un statut en JSON, qui commence donc par « { ».
    ///
    /// Les trois noms d'événements sont tirés au hasard pour chaque page, et
    /// faits de lettres seules : ils s'écrivent tels quels entre apostrophes.
    ///
    /// Inerte hors de chatgpt.com : les popups de connexion partagent la
    /// configuration de la page, donc ses scripts, et `getUserMedia` n'a pas à
    /// être enveloppé sur les pages de Google, d'Apple ou de Microsoft. Leur
    /// donner une autre configuration ferait échouer la connexion.
    ///
    /// Un statut part à l'armement, à chaque appel à `getUserMedia` et à
    /// chaque changement d'état du contexte : Swift n'attend rien au
    /// désarmement, il a déjà tout. « 0 appel » s'y lit comme « la page n'a
    /// pas demandé le micro ici », « aucun statut » comme « le script ne s'est
    /// pas exécuté ».
    public static func echo(evenement: String, armer: String, desarmer: String) -> String {
        """
        (() => { try {
          const hote = location.hostname;
          if (hote !== 'chatgpt.com' && !hote.endsWith('.chatgpt.com')) return;
          const md = window.MediaDevices && MediaDevices.prototype, cible = md && md.getUserMedia;
          if (typeof cible !== 'function') return;
          // Capturés avant tout script de la page, qui ne peut plus les dévier.
          const doc = document, emettre = doc.dispatchEvent.bind(doc);
          const Evenement = CustomEvent, alors = Promise.prototype.then;
          const envoyer = (s) => { try { emettre(new Evenement('\(evenement)', {detail: s})); } catch (e) {} };
          let appels = 0, flux = null, arme = false, ctx = null, noeuds = [];
          const statut = () => {
            let piste = null;
            try { piste = flux.getAudioTracks()[0].getSettings().sampleRate || null; } catch (e) {}
            envoyer(JSON.stringify({appels, piste, etat: ctx ? ctx.state : 'aucun', taux: ctx ? ctx.sampleRate : null}));
          };
          const fermer = () => {
            if (!ctx) return;
            const c = ctx; ctx = null;
            for (const n of noeuds.splice(0)) { try { n.disconnect(); } catch (e) {} }
            try { c.onstatechange = null; c.close().catch(() => {}); } catch (e) {}
          };
          const brancher = () => { try {
            const piste = flux && flux.getAudioTracks().find(p => p.readyState === 'live');
            if (ctx || !arme || !piste || !window.AudioContext) return;
            ctx = new AudioContext({sampleRate: 16000});
            const source = ctx.createMediaStreamSource(flux), proc = ctx.createScriptProcessor(4096, 1, 1);
            const muet = ctx.createGain(); muet.gain.value = 0;
            proc.onaudioprocess = (e) => { try {
              // La page arrête la piste sans qu'« ended » ne soit émis.
              if (piste.readyState === 'ended') return fermer();
              // Int16Array suit l'ordre de la machine : petit-boutiste sur tout Mac.
              const f = e.inputBuffer.getChannelData(0), n = new Int16Array(f.length);
              for (let i = 0; i < f.length; i++) n[i] = f[i] < 0 ? Math.max(-1, f[i]) * 32768 : Math.min(1, f[i]) * 32767;
              const o = new Uint8Array(n.buffer);
              let b = '';
              for (let i = 0; i < o.length; i += 8192) b += String.fromCharCode.apply(null, o.subarray(i, i + 8192));
              envoyer(btoa(b));
            } catch (e) {} };
            source.connect(proc); proc.connect(muet); muet.connect(ctx.destination); noeuds = [source, proc, muet];
            ctx.onstatechange = statut;
            statut();
            ctx.resume().catch(() => {});
          } catch (e) { fermer(); } };
          const retenir = (f) => { try {
            if (!f.getAudioTracks().some(p => p.readyState === 'live')) return;
            if (f !== flux) { fermer(); flux = f; }
            brancher();
          } catch (e) {} };
          md.getUserMedia = new Proxy(cible, { apply(c, moi, args) {
            appels++;
            if (arme) statut();
            const p = Reflect.apply(c, moi, args);
            try { Reflect.apply(alors, p, [retenir, () => {}]); } catch (e) {}
            return p;
          } });
          doc.addEventListener('\(armer)', () => { arme = true; statut(); brancher(); }, true);
          doc.addEventListener('\(desarmer)', () => { arme = false; fermer(); }, true);
        } catch (e) {} })();
        """
    }

    /// Le relais de l'écho vers Swift, dans le monde de Caspr.
    ///
    /// Le gestionnaire de messages vit dans ce monde-là, et non dans celui de
    /// la page : `window.webkit` y apparaîtrait à chatgpt.com (mesuré).
    public static func relaisEcho(evenement: String) -> String {
        """
        document.addEventListener('\(evenement)', (e) => { try {
          if (typeof e.detail === 'string') webkit.messageHandlers.casprEcho.postMessage(e.detail);
        } catch (x) {} }, true);
        """
    }
}
