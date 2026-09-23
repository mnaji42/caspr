import Foundation
import JavaScriptCore
import Testing
@testable import CasprCore

/// Le JavaScript du relais, vérifié hors de la page.
///
/// Dans chatgpt.com, un script qui ne se compile pas ne s'exécute jamais, et
/// rien ne le dit ; un script qui lève au mauvais endroit casse la page. Ici,
/// l'un et l'autre cassent `swift test`.
///
/// Le seul fichier qui importe JavaScriptCore : `CasprCore` reste sans
/// dépendance système.
@Suite("Scripts du relais")
struct RelaisScriptsTests {

    static let echo = RelaisScripts.echo(evenement: "evenement", armer: "armer",
                                         desarmer: "desarmer")

    /// Un faux navigateur : `MediaDevices` dont `getUserMedia` rend une
    /// promesse, un document qui garde ses écouteurs et ce qu'on lui émet, et
    /// `btoa` prêté par Swift — JavaScriptCore n'a pas d'API web.
    ///
    /// Chaque `evaluateScript` vide la file des microtâches en rendant la
    /// main : la promesse de `getUserMedia` est résolue à l'appel suivant.
    static func contexte(hote: String = "chatgpt.com") -> JSContext {
        let ctx = JSContext()!
        let btoa: @convention(block) (String) -> String = { s in
            Data(s.unicodeScalars.map { UInt8($0.value) }).base64EncodedString()
        }
        ctx.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        ctx.evaluateScript("""
            var window = this, emis = [], ecouteurs = {}, location = { hostname: '\(hote)' };
            var document = {
              addEventListener(n, f) { ecouteurs[n] = f; },
              dispatchEvent(e) { emis.push(e); return true; }
            };
            function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
            function MediaDevices() {}
            var piste = { readyState: 'live', getSettings() { return { sampleRate: 48000 }; } };
            var flux = { getAudioTracks() { return [piste]; } };
            var promesse = Promise.resolve(flux);
            MediaDevices.prototype.getUserMedia = function () { return promesse; };
            var md = new MediaDevices();
            """)
        return ctx
    }

    @Test("Chaque script se compile")
    func syntaxe() {
        let ctx = JSGlobalContextCreate(nil)!
        defer { JSGlobalContextRelease(ctx) }
        for source in [RelaisScripts.pont, Self.echo, RelaisScripts.relaisEcho(evenement: "evenement")] {
            let script = JSStringCreateWithUTF8CString(source)!
            defer { JSStringRelease(script) }
            #expect(JSCheckScriptSyntax(ctx, script, nil, 0, nil))
        }
    }

    /// Le pont s'installe. Une faute qui ne se voit qu'à l'exécution — un nom
    /// mal écrit au premier niveau, une constante déclarée deux fois — ne le
    /// laisserait pas en place, et sans échéance la dictée attendrait sans
    /// fin une page qui ne répondrait jamais.
    @Test("Le pont s'installe sur la page, une seule fois")
    func pontInstalle() {
        let ctx = JSContext()!
        ctx.evaluateScript("var window = this, document = {}, location = { hostname: 'chatgpt.com' };")
        ctx.evaluateScript(RelaisScripts.pont)
        #expect(ctx.exception == nil)
        #expect(ctx.evaluateScript("typeof window.__relais === 'object'")!.toBool())
        // Réinjecté — une navigation dans la même page —, il garde le premier.
        ctx.evaluateScript("var premier = window.__relais;")
        ctx.evaluateScript(RelaisScripts.pont)
        #expect(ctx.evaluateScript("window.__relais === premier")!.toBool())
    }

    /// La façade appelle le pont par ces noms-là : qu'un seul lui manque, et
    /// la dictée attendrait sans fin la réponse d'une fonction qui n'existe
    /// pas. Une fonction du pont que la façade ne nomme pas est du code mort.
    @Test("Le pont expose exactement les fonctions que la façade appelle")
    func fonctionsDuPont() {
        let ctx = JSContext()!
        ctx.evaluateScript("var window = this, document = {}, location = { hostname: 'chatgpt.com' };")
        ctx.evaluateScript(RelaisScripts.pont)
        // `pur` n'est pas une fonction de la page : les règles, pour les tests.
        let cles = ctx.evaluateScript("Object.keys(window.__relais).filter((c) => c !== 'pur')")!
            .toArray() as? [String] ?? []
        #expect(cles.sorted() == RelaisScripts.Fonction.allCases.map(\.rawValue).sorted())
        for cle in cles {
            #expect(ctx.evaluateScript("typeof window.__relais['\(cle)']")!.toString() == "function")
        }
    }

    /// Les règles du pont qui ne regardent pas la page, évaluées telles que
    /// la page les exécute.
    static func regle(_ appel: String) -> Bool {
        let ctx = JSContext()!
        ctx.evaluateScript("var window = this, document = {}, location = { hostname: 'chatgpt.com' };")
        ctx.evaluateScript(RelaisScripts.pont)
        return ctx.evaluateScript("window.__relais.pur.\(appel)")!.toBool()
    }

    /// Un identifiant fabriqué à chaque rendu vise, à la dictée suivante, un
    /// élément qui n'existe plus ; un numéro final, le message d'un autre fil.
    @Test("Aucun repère n'est tiré d'un identifiant engendré")
    func identifiantsEngendres() {
        for id in ["", "radix-_r_6s_", ":r1:", "_r_12_", "«r3»", "conversation-turn-6", "item_12", "x1234"] {
            #expect(Self.regle("idEngendre('\(id)')"), "\(id)")
        }
        for id in ["prompt-textarea", "send-button", "composer-speech-button", "copy-turn-action-button"] {
            #expect(!Self.regle("idEngendre('\(id)')"), "\(id)")
        }
    }

    /// Dans un projet aussi : c'est le point de départ que les réglages
    /// recommandent, et ne pas l'y reconnaître y laissait le fil ouvert.
    @Test("Une conversation se reconnaît à son adresse, dans un projet aussi")
    func conversation() {
        #expect(Self.regle("estConversation('/c/68d2-abc')"))
        #expect(Self.regle("estConversation('/g/g-p-123-caspr/c/68d2-abc')"))
        for chemin in ["/", "/g/g-p-123-caspr", "/g/g-p-123-caspr/project", "/gpts", "/codex"] {
            #expect(!Self.regle("estConversation('\(chemin)')"), "\(chemin)")
        }
    }

    @Test("L'écran d'authentification se reconnaît à son adresse, et à elle seule")
    func authentification() {
        #expect(Self.regle("estAuthentification({ hostname: 'chatgpt.com', pathname: '/auth/login' })"))
        #expect(Self.regle("estAuthentification({ hostname: 'chatgpt.com', pathname: '/log-in' })"))
        #expect(Self.regle("estAuthentification({ hostname: 'auth.openai.com', pathname: '/u/login' })"))
        #expect(!Self.regle("estAuthentification({ hostname: 'chatgpt.com', pathname: '/' })"))
        #expect(!Self.regle("estAuthentification({ hostname: 'chatgpt.com', pathname: '/authors' })"))
        #expect(!Self.regle("estAuthentification({ hostname: 'chatgpt.com', pathname: '/c/login-page' })"))
    }

    /// Étroits, délibérément : une bannière de quota affichée des jours
    /// interromprait sinon chaque dictée.
    @Test("Les motifs d'échec restent étroits ; seul un bouton qui invite à se connecter compte")
    func motifs() {
        for texte in ["Je n'ai pas compris", "Nous n'avons pas compris l'audio", "Sorry, I didn't catch that",
                      "Something went wrong. Try again", "Veuillez réessayer"] {
            #expect(Self.regle("estEchec(\"\(texte)\")"), "\(texte)")
        }
        for texte in ["Limite d'utilisation hebdomadaire bientôt atteinte", "Mise à niveau disponible"] {
            #expect(!Self.regle("estEchec(\"\(texte)\")"), "\(texte)")
        }
        for texte in ["Se connecter", "Connexion", "Log in", "Sign up for free", "S'inscrire gratuitement"] {
            #expect(Self.regle("estInvite(\"\(texte)\")"), "\(texte)")
        }
        for texte in ["Se déconnecter", "Déconnexion", "Nouvelle conversation", "Partager"] {
            #expect(!Self.regle("estInvite(\"\(texte)\")"), "\(texte)")
        }
    }

    /// Un pont posé sur un faux document : `querySelectorAll` lève sur un
    /// sélecteur invalide, comme le vrai, et ne connaît que le bouton d'envoi.
    static func pontSurFauxDocument() -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
            var window = this, ecouteur = null, resultat = null;
            var bouton = { tagName: 'BUTTON', nodeType: 1, id: '', parentElement: null,
              matches() { return true; }, closest() { return bouton; },
              getAttribute(n) { return n === 'data-testid' ? 'send-button' : null; } };
            var document = {
              querySelectorAll(s) {
                if (s.startsWith('[[')) throw new SyntaxError('sélecteur invalide');
                return s.includes('send-button') ? [bouton] : [];
              },
              addEventListener(n, f) { ecouteur = f; },
              removeEventListener() { ecouteur = null; }
            };
            var location = { hostname: 'chatgpt.com' };
            """)
        ctx.evaluateScript(RelaisScripts.pont)
        return ctx
    }

    /// Un repère appris d'une page qui a changé peut ne plus se lire. Il ne
    /// désigne alors rien — « introuvable », que l'attente sait observer —, et
    /// ne lève pas : une exception se lirait comme un silence du pont.
    @Test("Un repère devenu invalide ne désigne rien, et ne lève rien")
    func repereInvalide() {
        let ctx = Self.pontSurFauxDocument()
        for appel in ["cliquerBouton('[[', 'button')", "cliquerBouton('', '[[')",
                      "copierLaReponse('[[', 'button', '')", "copierLaReponse('', '[[', '[[')",
                      "lireReponse('[[')", "candidatsCopier('[[')"] {
            #expect(ctx.evaluateScript("window.__relais.\(appel).ok")!.toBool() == false, "\(appel)")
        }
        #expect(ctx.exception == nil)
    }

    /// Caspr clique la page pour la piloter : un de ses clics retenu par une
    /// calibration en cours y apprendrait le mauvais bouton.
    @Test("La calibration ne retient qu'un clic de la main, et renonce sur demande")
    func calibrationGuette() {
        let ctx = Self.pontSurFauxDocument()
        ctx.evaluateScript("window.__relais.calibrer('bouton').then((r) => { resultat = r; });")
        ctx.evaluateScript("ecouteur({ isTrusted: false, target: bouton });")
        #expect(ctx.evaluateScript("resultat === null")!.toBool())
        ctx.evaluateScript("ecouteur({ isTrusted: true, target: bouton });")
        #expect(ctx.evaluateScript("resultat.ok && resultat.selecteur")!.toString()
                == #"[data-testid="send-button"]"#)
        #expect(ctx.evaluateScript("ecouteur === null")!.toBool())

        ctx.evaluateScript("resultat = null; window.__relais.calibrerAvecMenu().then((r) => { resultat = r; });")
        #expect(ctx.evaluateScript("window.__relais.abandonnerCalibration().ok")!.toBool())
        #expect(ctx.evaluateScript("resultat.ok === false && ecouteur === null")!.toBool())
        #expect(ctx.exception == nil)
    }

    @Test("La page reçoit la promesse d'origine, et rien d'autre ne change pour elle")
    func promesseIntacte() throws {
        let ctx = Self.contexte()
        ctx.evaluateScript(Self.echo)
        #expect(ctx.exception == nil)
        let r = ctx.evaluateScript("""
            [md.getUserMedia({audio: true}) === promesse,
             Object.getOwnPropertyNames(md).length,
             typeof MediaDevices.prototype.getUserMedia]
            """)!
        #expect(r.atIndex(0).toBool())
        #expect(r.atIndex(1).toInt32() == 0)
        #expect(r.atIndex(2).toString() == "function")
    }

    @Test("Hors de chatgpt.com — un popup de connexion —, l'écho ne touche à rien")
    func inerteHorsDeChatGPT() {
        let ctx = Self.contexte(hote: "accounts.google.com")
        ctx.evaluateScript("var origine = MediaDevices.prototype.getUserMedia;")
        ctx.evaluateScript(Self.echo)
        #expect(ctx.exception == nil)
        #expect(ctx.evaluateScript("MediaDevices.prototype.getUserMedia === origine")!.toBool())
        #expect(ctx.evaluateScript("Object.keys(ecouteurs).length")!.toInt32() == 0)
    }

    @Test("Sans AudioContext, dans l'ordre d'une dictée, rien ne lève et l'appel se dit sur-le-champ")
    func sansAudioContext() {
        let ctx = Self.contexte()
        ctx.evaluateScript(Self.echo)
        // Armé d'abord, puis le clic du micro : la page appelle getUserMedia.
        ctx.evaluateScript("ecouteurs.armer();")
        ctx.evaluateScript("md.getUserMedia({audio: true});")
        ctx.evaluateScript("ecouteurs.desarmer();")
        #expect(ctx.exception == nil)
        // Swift n'attend rien au désarmement : l'appel doit être dit quand il
        // a lieu, même quand aucun contexte ne se branche ensuite.
        let statut = ctx.evaluateScript("emis[emis.length - 1].detail")!.toString()!
        #expect(statut.hasPrefix("{"))
        #expect(statut.contains("\"appels\":1"))
        #expect(statut.contains("\"etat\":\"aucun\""))
    }

    @Test("Armé avant le clic, le son part en Int16 petit-boutiste ; la piste finie ferme tout")
    func sonTransmis() throws {
        let ctx = Self.contexte()
        ctx.evaluateScript("""
            var proc = null, ferme = false;
            function AudioContext(o) { this.sampleRate = o.sampleRate; this.state = 'running'; }
            var noeud = () => ({ connect() {}, disconnect() {} });
            AudioContext.prototype = {
              createMediaStreamSource(f) { return noeud(); },
              createScriptProcessor() { proc = noeud(); return proc; },
              createGain() { const g = noeud(); g.gain = { value: 1 }; return g; },
              destination: {},
              resume() { return Promise.resolve(); },
              close() { ferme = true; return Promise.resolve(); }
            };
            """)
        ctx.evaluateScript(Self.echo)
        ctx.evaluateScript("ecouteurs.armer();")
        ctx.evaluateScript("md.getUserMedia({audio: true});")
        #expect(ctx.evaluateScript("proc !== null")!.toBool())
        ctx.evaluateScript("""
            proc.onaudioprocess({ inputBuffer: { getChannelData() {
              return new Float32Array([0, 1, -1, 0.5]); } } });
            """)
        #expect(ctx.exception == nil)
        let details = ctx.evaluateScript("emis.map(e => e.detail)")!.toArray() as? [String] ?? []
        let son = try #require(details.first { !$0.hasPrefix("{") })
        let octets = try #require(Data(base64Encoded: son))
        let valeurs = stride(from: 0, to: octets.count, by: 2).map {
            Int16(bitPattern: UInt16(octets[$0]) | UInt16(octets[$0 + 1]) << 8)
        }
        #expect(valeurs == [0, 32767, -32768, 16383])
        #expect(details.contains { $0.contains("\"piste\":48000") && $0.contains("\"taux\":16000") })

        ctx.evaluateScript("""
            piste.readyState = 'ended';
            proc.onaudioprocess({ inputBuffer: { getChannelData() { return new Float32Array(4); } } });
            """)
        #expect(ctx.evaluateScript("ferme")!.toBool())

        // Désarmé, l'écho se tait : Swift a déjà conclu.
        ctx.evaluateScript("emis = []; ecouteurs.desarmer(); md.getUserMedia({audio: true});")
        #expect(ctx.evaluateScript("emis.length")!.toInt32() == 0)
    }
}
