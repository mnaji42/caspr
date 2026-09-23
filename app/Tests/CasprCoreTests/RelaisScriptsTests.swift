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
        for source in [Self.echo, RelaisScripts.relaisEcho(evenement: "evenement")] {
            let script = JSStringCreateWithUTF8CString(source)!
            defer { JSStringRelease(script) }
            #expect(JSCheckScriptSyntax(ctx, script, nil, 0, nil))
        }
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
