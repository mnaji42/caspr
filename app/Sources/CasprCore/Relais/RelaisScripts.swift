import Foundation

/// Le JavaScript que Caspr injecte dans la page ChatGPT, en chaînes.
///
/// Ici, dans `CasprCore`, parce que les tests l'atteignent : une faute de
/// syntaxe casse `swift test` (cf. `RelaisScriptsTests`). Dans la page, elle
/// ne se verrait pas — le script ne s'exécuterait simplement jamais, et rien
/// ne le dirait.
public enum RelaisScripts {

    /// Les fonctions de `window.__relais`, par leur nom.
    ///
    /// Un nom mal écrit ne faisait qu'une erreur JavaScript, avalée comme un
    /// silence : sans échéance, une attente sans fin. Ici, il ne compile pas,
    /// et les tests vérifient que le pont expose ces fonctions-là, et elles
    /// seules.
    public enum Fonction: String, CaseIterable, Sendable {
        case cliquer, lire, vider, ecrire, encadrer, depart, copierLaReponse, cliquerBouton
        case lireReponse, compacter, oublierBrouillon, candidats, candidatsCopier
        case calibrer, calibrerAvecMenu, abandonnerCalibration
        case etat, releve, erreur, etatReponse
    }

    /// Le pont injecté dans la page.
    ///
    /// Il ne fait rien qu'un utilisateur ne ferait à la souris : cliquer deux
    /// boutons, lire la zone de texte, la vider. Il n'envoie aucun message, ne
    /// touche à aucune conversation, n'appelle aucun point d'entrée réseau.
    public static let pont = #"""
    (() => {
      if (window.__relais) return;

      const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s;

      // Les réponses de ChatGPT, et elles seules : le rôle est posé sur chaque
      // message par son auteur, là où `article` porte aussi ceux de
      // l'utilisateur.
      const REPONSES = '[data-message-author-role="assistant"]';

      // Filet de secours tant que l'utilisateur n'a pas calibré, et rien de
      // plus : ce sont des paris sur des libellés d'accessibilité, pas un
      // contrat. Le chemin normal est le sélecteur appris.
      //
      // `voice` est volontairement absent de la liste du micro : c'est le
      // libellé du mode vocal — la pastille bleue — qui ouvre une conversation
      // parlée au lieu de dicter dans la zone de texte.
      const HEURISTIQUES = {
        micro: [
          '[data-testid="composer-speech-button"]',
          'button[aria-label*="dict" i]',
          'button[aria-label*="dicté" i]',
          'button[aria-label*="micro" i]',
        ],
        stop: [
          '[data-testid="composer-speech-button-stop"]',
          'button[aria-label*="stop" i]',
          'button[aria-label*="arrêt" i]',
          'button[aria-label*="arret" i]',
          'button[aria-label*="termin" i]',
        ],
        composeur: [
          '#prompt-textarea',
          'div[contenteditable="true"]',
          'textarea',
        ],
        envoi: [
          '[data-testid="send-button"]',
          'button[aria-label*="envoy" i]',
          'button[aria-label*="send" i]',
        ],
        reponse: [
          REPONSES,
          'article',
        ],
        copier: [
          '[data-testid="copy-turn-action-button"]',
          'button[aria-label*="copi" i]',
          'button[aria-label*="copy" i]',
        ],
        lecture: [
          '[data-testid="voice-play-turn-action-button"]',
          'button[aria-label*="haute voix" i]',
          'button[aria-label*="read aloud" i]',
        ],
      };

      const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0;

      // Ce qu'un repère doit désigner pour vouloir dire quelque chose.
      //
      // Un sélecteur n'est pas une adresse : c'est une question posée à la
      // page, et plusieurs éléments peuvent y répondre. ChatGPT pose le même
      // libellé d'accessibilité sur la zone de saisie **et** sur le bloc qui
      // l'entoure ; retenir le libellé sans rien vérifier faisait désigner le
      // bloc. On écrivait alors dedans sans effet visible, et surtout on le
      // relisait vide — un bloc n'a pas de texte à lui. La dictée arrivait bien
      // dans ChatGPT, et Caspr concluait « rien n'a été entendu ».
      //
      // D'où le genre : une zone de saisie doit être une zone de saisie, un
      // bouton doit être un bouton. Le genre sert trois fois — pour retrouver
      // un élément, pour juger un repère au moment où on l'apprend, et pour
      // écarter les clics hors sujet pendant la calibration — et c'est la même
      // idée les trois fois : un repère ne vaut que s'il désigne encore la
      // même chose qu'au moment où on l'a appris.
      const GENRE = {
        micro: 'bouton', stop: 'bouton', envoi: 'bouton',
        copier: 'bouton', lecture: 'bouton',
        composeur: 'saisie',
        reponse: 'texte',
      };

      // Ce sur quoi un clic compte, selon ce qu'on cherche. Cliquer le texte
      // qu'on vient de taper n'est pas cliquer le bouton d'envoi.
      const CLIQUABLE = {
        saisie: '[contenteditable="true"], textarea, input',
        bouton: 'button, [role="button"], [role="menuitem"]',
      };

      const convient = (genre, el) => {
        if (!el) return false;
        if (genre === 'saisie') {
          return el.isContentEditable
            || el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
        }
        if (genre === 'bouton') {
          return el.tagName === 'BUTTON'
            || el.getAttribute('role') === 'button'
            || el.getAttribute('role') === 'menuitem';
        }
        return true;
      };

      // Le filet tant que rien n'a été appris. Des paris sur des libellés, pas
      // un contrat.
      function heuristique(cible) {
        for (const s of (HEURISTIQUES[cible] || [])) {
          for (const el of document.querySelectorAll(s)) {
            if (visible(el) && convient(GENRE[cible], el)) return el;
          }
        }
        return null;
      }

      function trouver(cible, selecteur) {
        // Un repère appris qui ne trouve rien veut dire **absent**, et non
        // « cherchons quelque chose qui lui ressemble ».
        //
        // C'est la leçon d'une dictée perdue trois fois de suite. Pendant
        // l'enregistrement, ChatGPT retire la zone de saisie de la page :
        // `#prompt-textarea` ne désigne alors plus rien, ce qui est normal et
        // momentané. On se rabattait sur les heuristiques, qui cherchent « une
        // zone éditable » — et la conversation en contenait une autre, le
        // document que ChatGPT avait produit à la réorganisation précédente.
        // Chaque dictée rendait donc ce document au lieu de ce qu'on venait de
        // dire, en une seconde et demie et au caractère près. Rien ne le
        // signalait : le texte était plausible, il était simplement d'avant.
        //
        // Les heuristiques restent le filet de qui n'a pas encore calibré, et
        // c'est tout. Un repère appris qui casse pour de bon donne un échec
        // explicite, et recalibrer coûte six clics.
        //
        // Présence, et non visibilité, pour un sélecteur calibré : WebKit ne
        // dispose pas la page tant que sa fenêtre n'a jamais été affichée, et
        // la nôtre naît hors champ — `getClientRects()` rend alors une liste
        // vide pour des éléments pourtant bien là. Le bouton d'arrêt, créé au
        // clic, y échouait systématiquement à la première dictée. Un sélecteur
        // calibré désigne un élément que l'utilisateur a cliqué lui-même : rien
        // ne justifie de lui redemander ses dimensions.
        if (!selecteur) return heuristique(cible);
        try {
          // Le premier qui **convienne**, et non le premier tout court : la
          // page pose le même libellé sur la zone de saisie et sur le bloc qui
          // l'entoure, et `querySelector` rendrait le bloc.
          for (const el of document.querySelectorAll(selecteur)) {
            if (el.isConnected && convient(GENRE[cible], el)) return el;
          }
        } catch (e) {
          // Sélecteur devenu invalide : il ne dit plus rien du tout, alors que
          // « ne trouve rien » disait quelque chose.
          return heuristique(cible);
        }
        return null;
      }

      // Un identifiant engendré par la page ne désigne rien demain.
      //
      // Les bibliothèques de composants en fabriquent à chaque rendu —
      // `#radix-_r_6s_` et ses semblables. Retenu comme repère, il vise un
      // élément qui n'existera plus à la dictée suivante : le clic part dans le
      // vide sans que rien ne le signale. Un `data-testid` ou un libellé
      // d'accessibilité, eux, sont écrits par la page pour durer.
      //
      // Un numéro final dit la même chose autrement : `conversation-turn-6`
      // désigne le sixième message, qui n'est pas celui du fil suivant — et
      // pris pour le bloc d'une réponse, il faisait chercher le bouton
      // « copier » sous le message de l'utilisateur.
      const idEngendre = (id) => !id
        || /radix|^[:_]|_r_|^«|\d{3,}|[-_]\d+$/i.test(id);

      // Un repère ne vaut que s'il retrouve l'élément qu'on a cliqué.
      //
      // C'est la vérification qui manquait, et son absence a coûté cher :
      // l'attribut existait, on en tirait un sélecteur, et personne ne
      // demandait jamais ce que ce sélecteur désignait vraiment. Le libellé de
      // la zone de saisie était aussi porté par le bloc qui l'entoure, posé
      // plus haut dans le document ; c'est donc le bloc qu'on retenait, et
      // toutes les dictées se lisaient vides.
      //
      // On juge le repère avec la règle qui servira à s'en servir — les
      // éléments du bon genre, dans l'ordre du document — et on ne le garde
      // que si l'élément cliqué en fait partie. Plusieurs réponses sont
      // permises : la page pose un bouton « copier » sous chaque message, et
      // c'est le bloc parent, retenu au même clic, qui dira lequel.
      function repereValide(selecteur, el, genre) {
        let candidats = [];
        try { candidats = [...document.querySelectorAll(selecteur)]; }
        catch (e) { return false; }
        return candidats.filter((c) => convient(genre, c)).includes(el);
      }

      // Les repères qu'un élément porte, du plus solide au plus fragile.
      function reperesPossibles(el) {
        const guillemets = (v) => v.replace(/"/g, '\\"');
        const candidats = [];
        // Le même garde-fou que pour l'identifiant : un `data-testid` est
        // écrit pour durer, sauf quand la page y met un numéro d'ordre.
        const testid = el.getAttribute('data-testid');
        if (!idEngendre(testid)) candidats.push('[data-testid="' + guillemets(testid) + '"]');
        if (!idEngendre(el.id)) candidats.push('#' + esc(el.id));
        const aria = el.getAttribute('aria-label');
        if (aria) candidats.push('[aria-label="' + guillemets(aria) + '"]');
        return candidats;
      }

      function reperesDe(el, genre) {
        for (const c of reperesPossibles(el)) {
          if (repereValide(c, el, genre)) return c;
        }
        return '';
      }

      // L'élément est-il le **seul** à répondre à ce sélecteur ?
      //
      // Avec un genre, selon la règle de `trouver` — connectés, et du bon
      // genre — pour un repère cherché dans tout le document. Sans genre, tout
      // ce qui répond compte : c'est la règle de la paire « copier », où la
      // page prend le premier élément du bloc sans rien filtrer.
      const seulDans = (selecteur, portee, el, genre) => {
        let tous = [];
        try { tous = [...portee.querySelectorAll(selecteur)]; } catch (e) { return false; }
        const retenus = genre ? tous.filter((c) => c.isConnected && convient(genre, c)) : tous;
        return retenus.length === 1 && retenus[0] === el;
      };

      // Le repère qu'apprend la calibration automatique : une adresse, pas
      // une ressemblance.
      //
      // `repereValide` ne peut pas servir ici. Il vérifie que le sélecteur
      // retrouve l'élément — mais l'automate a trouvé l'élément *par* ce
      // sélecteur : la question contient sa réponse. Ce qui dit quelque chose,
      // c'est l'unicité : qu'un seul élément, du bon genre, y réponde. Le
      // reste de la preuve est dans l'effet, que Swift observe.
      //
      // Jamais le sélecteur du filet qui a trouvé l'élément : ceux qui sont
      // des adresses (`data-testid`, `#prompt-textarea`), l'élément les porte
      // et `reperesPossibles` les propose déjà ; les autres
      // (`div[contenteditable]`, `textarea`, `aria-label*=`) sont des
      // ressemblances. Seule sur l'accueil vide, une zone éditable
      // quelconque passait la preuve — puis, la zone de saisie retirée
      // pendant l'enregistrement, le repère rendait le canevas d'à côté au
      // lieu de dire « absent ».
      function repereUnique(el, portee, genre) {
        for (const c of reperesPossibles(el)) {
          if (seulDans(c, portee, el, genre)) return c;
        }
        return '';
      }

      // Un bouton qui ouvre un menu, la page le déclare (cf.
      // `calibrerAvecMenu`). L'automate ne le clique jamais : le menu « … »
      // de la réponse porte « Régénérer » et « Supprimer ».
      const ouvreUnMenu = (el) => !!el.getAttribute('aria-haspopup')
        || el.getAttribute('aria-expanded') !== null;

      // Le bouton « copier » et le bloc qui le porte, désignés sans
      // ambiguïté : le bloc est le dernier visible de son sélecteur — c'est
      // celui que `copierLaReponse` choisira — et le bouton y est seul.
      function paireCopier(el) {
        let n = el.parentElement;
        for (let i = 0; i < 5 && n; i++) {
          for (const selParent of reperesPossibles(n)) {
            let blocs = [];
            try { blocs = [...document.querySelectorAll(selParent)]; } catch (e) { continue; }
            const vus = blocs.filter((b) => b.getClientRects().length > 0);
            const liste = vus.length ? vus : blocs;
            if (liste[liste.length - 1] !== n) continue;
            const selecteur = repereUnique(el, n, null);
            if (selecteur) return { selecteur, parent: selParent };
          }
          n = n.parentElement;
        }
        return null;
      }

      // La dernière réponse visible, cherchée comme la dictée la cherche : par
      // le repère appris de la réponse s'il y en a un, par le filet sinon.
      //
      // Une seule fonction pour la dictée et pour la calibration automatique :
      // un bouton « copier » éprouvé depuis une autre réponse que celle d'où
      // la dictée partira n'aurait rien prouvé.
      //
      // Le filet ne sert qu'à qui n'a pas de repère : un repère appris qui ne
      // trouve rien dit que la réponse n'est pas encore là, et le filet
      // aurait rendu à sa place le premier `article` venu — le message de
      // l'utilisateur, dans un fil neuf.
      function derniereReponse(selReponse) {
        let reponses = [];
        if (selReponse) {
          try { reponses = [...document.querySelectorAll(selReponse)]; } catch (e) {}
        } else {
          for (const s of HEURISTIQUES.reponse) {
            reponses = [...document.querySelectorAll(s)];
            if (reponses.length) break;
          }
        }
        const vues = reponses.filter((el) => el.getClientRects().length > 0);
        return vues.length ? vues[vues.length - 1] : null;
      }

      // Le bouton que désigne un repère « copier » appris sans bloc : en
      // remontant depuis la dernière réponse, au premier niveau où le repère
      // répond, et à condition d'y répondre **seul**.
      //
      // Plus haut, on entrerait dans les messages voisins. Plusieurs au même
      // niveau, c'est par exemple une réponse qui porte aussi un bloc de
      // code — et deviner lequel est le bouton du tour, c'est ce qui s'est
      // trompé chaque fois qu'on l'a essayé : `null`, plutôt qu'un choix.
      function copierAutour(depart, selCopier) {
        let noeud = depart;
        for (let niveau = 0; niveau < 6 && noeud; niveau++) {
          let els = [];
          try { els = [...noeud.querySelectorAll(selCopier)]; } catch (e) { return null; }
          const boutons = els.filter((b) => visible(b) && convient('bouton', b));
          if (boutons.length) return boutons.length === 1 ? boutons[0] : null;
          noeud = noeud.parentElement;
        }
        return null;
      }

      // Un sélecteur qui a une chance de survivre au prochain déploiement.
      //
      // Par ordre de solidité : `data-testid`, identifiant, libellé
      // d'accessibilité.
      //
      // Le libellé passe en dernier parce qu'il est écrit dans la langue de
      // l'interface : `[aria-label="Discuter avec ChatGPT"]` ne désigne plus
      // rien le jour où l'on passe ChatGPT en anglais, là où `#prompt-textarea`
      // tient. L'identifiant, lui, ne vient en second que depuis qu'on écarte
      // ceux que les bibliothèques de composants fabriquent à chaque rendu :
      // c'était la seule raison de s'en méfier.
      //
      // Le chemin structurel n'est qu'un dernier recours — il casse au moindre
      // remaniement, mais recalibrer coûte trois clics.
      function selecteurStable(el, genre) {
        const repere = reperesDe(el, genre);
        if (repere) return repere;

        const parts = [];
        let n = el;
        while (n && n.nodeType === 1 && parts.length < 6) {
          if (!idEngendre(n.id)) { parts.unshift('#' + esc(n.id)); break; }
          let part = n.tagName.toLowerCase();
          const p = n.parentElement;
          if (p) {
            const memes = [...p.children].filter((c) => c.tagName === n.tagName);
            if (memes.length > 1) part += ':nth-of-type(' + (memes.indexOf(n) + 1) + ')';
          }
          parts.unshift(part);
          n = p;
        }
        return parts.join(' > ');
      }

      // Le premier ancêtre qui porte un repère valide.
      //
      // Capturé en même temps que l'élément lui-même, il permet de désigner
      // « ce bouton, dans ce bloc » plutôt que « un bouton qui ressemble à
      // celui-ci ». Pour le bouton « copier », la différence est décisive : la
      // page en contient un par message, et seule la paire dit lequel.
      //
      // Aucun genre exigé : un bloc n'est ni un bouton ni une zone de saisie,
      // il lui suffit d'être retrouvable.
      function selecteurAncetre(el) {
        let n = el.parentElement;
        for (let i = 0; i < 5 && n; i++) {
          const repere = reperesDe(n, 'bloc');
          if (repere) return repere;
          n = n.parentElement;
        }
        return '';
      }

      // Les motifs d'un échec que ChatGPT écrit en toutes lettres.
      //
      // Étroits, délibérément. Accepter n'importe quelle alerte visible faisait
      // prendre pour un échec de dictée la bannière « Limite d'utilisation
      // hebdomadaire bientôt atteinte », qui porte le même rôle et reste
      // affichée des jours durant : chaque dictée aurait été interrompue. Ce
      // qu'un motif ne connaît pas se reconnaît autrement — à ce qu'il est
      // apparu depuis la demande (cf. `erreur`).
      const MOTIFS_ECHEC = /n'a pas compris|pas compris|didn.t catch|try again|réessayer/i;

      // Les textes des alertes affichées. `role="alert"` est un rôle
      // d'accessibilité normalisé, et non une classe générée.
      const alertesVisibles = () => [...document.querySelectorAll('[role="alert"]')]
        .filter((el) => el.getClientRects().length > 0)
        .map((el) => (el.innerText || '').trim())
        .filter((t) => t);

      // Les échecs écrits hors de toute alerte, pour les pages qui n'en posent
      // pas.
      //
      // Cherchés là où ils peuvent être seulement : le dernier tour de la
      // conversation, et le formulaire de la zone de saisie. Parcourir tous
      // les `div, span, p` du document, c'était lire `innerText` sur des
      // milliers d'éléments — chaque lecture force la page à recalculer sa
      // disposition — plusieurs fois par seconde, sur une conversation qu'on
      // attendait justement de voir avancer.
      //
      // Dans ce tour, jamais le texte d'un message — ni ce qui le contient.
      // La réponse de ChatGPT peut dire « on peut réessayer », la dictée
      // envoyée « try again » : lus comme des échecs, ils faisaient jeter
      // une réponse juste, ou conclure au refus avant même que ChatGPT ait
      // répondu. Reste ce que la page dessine autour du message, où elle pose
      // ses propres avis d'échec. Un échec écrit ailleurs n'est pas deviné :
      // l'attente continue, et la touche de dictée en sort.
      const MESSAGE = '[data-message-author-role]';
      const echecsEcrits = () => {
        const zones = [];
        const tours = document.querySelectorAll('article');
        if (tours.length) zones.push(tours[tours.length - 1]);
        const formulaires = document.querySelectorAll('main form');
        if (formulaires.length) zones.push(formulaires[formulaires.length - 1]);
        const textes = [];
        for (const zone of zones) {
          for (const el of zone.querySelectorAll('div, span, p')) {
            if (el.closest(MESSAGE) || el.querySelector(MESSAGE)) continue;
            const t = (el.innerText || '').trim();
            if (t && t.length < 120 && MOTIFS_ECHEC.test(t)
                && el.getClientRects().length > 0) textes.push(t);
          }
        }
        return textes;
      };

      // ChatGPT est-il en train d'écrire sa réponse ?
      //
      // Le bouton qui arrête la génération le dit sans calibration : il
      // n'existe que pendant l'écriture. Aucun repère appris ne le désigne ;
      // les libellés d'arrêt que le filet connaît déjà — « stop », « arrêt »
      // — le désignent aussi, et on les réutilise, hors des messages, où la
      // page pose d'autres boutons.
      const generationEnCours = () => {
        for (const s of HEURISTIQUES.stop) {
          for (const el of document.querySelectorAll(s)) {
            if (el.closest('article, [data-message-author-role]')) continue;
            if (visible(el) && convient('bouton', el)) return true;
          }
        }
        return false;
      };

      window.__relais = {
        cliquer(cible, selecteur) {
          const el = trouver(cible, selecteur);
          if (!el) return { ok: false, raison: 'introuvable' };
          el.click();
          return { ok: true };
        },

        lire(selecteur) {
          const el = trouver('composeur', selecteur);
          if (!el) return { ok: false, raison: 'introuvable' };
          const t = (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT')
            ? el.value : el.innerText;
          // L'espace insécable vient du rendu, pas de la dictée : le laisser
          // ferait arriver des U+00A0 dans le code et les terminaux.
          return { ok: true, texte: (t || '').replace(/ /g, ' ').trim() };
        },

        vider(selecteur) {
          const el = trouver('composeur', selecteur);
          if (!el) return { ok: false, raison: 'introuvable' };
          el.focus();
          // Passer par execCommand plutôt qu'écraser textContent : le composeur
          // est un éditeur ProseMirror, dont l'état interne se désynchronise si
          // on modifie le DOM dans son dos. Le symptôme serait un brouillon qui
          // réapparaît à la frappe suivante.
          let fait = false;
          try {
            document.execCommand('selectAll', false, null);
            fait = document.execCommand('delete', false, null);
          } catch (e) { fait = false; }
          if (!fait) {
            if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') el.value = '';
            else el.textContent = '';
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          // Rendre le focus. Le prendre était nécessaire — ProseMirror ne se
          // vide pas autrement — mais le garder faisait de cette page le champ
          // focalisé du système, et la dictée s'écrivait ici au lieu de
          // l'éditeur de l'utilisateur.
          el.blur();
          return { ok: true };
        },

        // Dépose un texte dans la zone de saisie, en remplaçant ce qui s'y
        // trouve.
        //
        // `insertText` et non une écriture directe dans le DOM : le composeur
        // est un éditeur ProseMirror, dont l'état interne se désynchronise si
        // on le modifie dans son dos — le message partirait vide. Les retours
        // à la ligne du texte n'envoient rien : seule une frappe sur Entrée le
        // ferait, et on ne la simule pas.
        ecrire(selecteur, texte) {
          const el = trouver('composeur', selecteur);
          if (!el) return { ok: false, raison: 'introuvable' };
          el.focus();
          let fait = false;
          try {
            document.execCommand('selectAll', false, null);
            fait = document.execCommand('insertText', false, texte);
          } catch (e) { fait = false; }
          if (!fait) {
            if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') el.value = texte;
            else el.textContent = texte;
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          // Rendre le focus : le garder ferait de cette page le champ focalisé
          // du système, et l'insertion au curseur écrirait ici.
          el.blur();
          return { ok: true };
        },

        // Encadre le texte déjà présent, sans le réécrire.
        //
        // C'est le point de conception qui manquait. La transcription est déjà
        // dans la zone de saisie : la relire, recharger la page, puis la
        // repousser caractère par caractère avec la consigne devant, c'était
        // demander à un éditeur ProseMirror d'avaler dix minutes de texte d'un
        // coup — d'où les à-coups, et un prompt qui apparaissait puis
        // disparaissait. On n'insère plus que la consigne, aux deux bouts.
        //
        // L'insertion passe par la sélection : on la replie sur la fin, on
        // écrit, on la replie sur le début, on écrit. `insertText` respecte
        // l'état interne de l'éditeur là où une écriture directe dans le DOM le
        // désynchronise.
        encadrer(selecteur, avant, apres) {
          const el = trouver('composeur', selecteur);
          if (!el) return { ok: false, raison: 'introuvable' };
          el.focus();
          const sel = window.getSelection();

          const placer = (auDebut) => {
            const r = document.createRange();
            r.selectNodeContents(el);
            r.collapse(auDebut);
            sel.removeAllRanges();
            sel.addRange(r);
          };

          try {
            if (apres) { placer(false); document.execCommand('insertText', false, apres); }
            if (avant) { placer(true); document.execCommand('insertText', false, avant); }
          } catch (e) {
            return { ok: false, raison: String(e) };
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          // Rendre le focus : le garder ferait de cette page le champ focalisé
          // du système, et l'insertion au curseur écrirait ici.
          el.blur();
          return { ok: true };
        },

        // Clique le bouton « copier » de la réponse.
        //
        // Une paire calibrée — le bloc d'actions de la réponse, puis le bouton
        // dedans — et non une recherche qui remonte l'arbre en devinant. La
        // page contient un bouton « copier » par message, celui de
        // l'utilisateur compris ; seule la paire dit lequel, et elle le dit
        // sans ambiguïté.
        //
        // Rien n'est écrit en dur : les libellés d'accessibilité changent avec
        // la langue de l'interface, et un sélecteur codé pour le français
        // laisserait tomber tout le monde ailleurs. C'est la calibration qui
        // les apprend, l'un et l'autre, d'un seul clic.
        //
        // Le repère appris, et lui seul. Ne rien trouver veut dire que le
        // bouton n'est **pas encore là** — il n'apparaît qu'une fois la
        // réponse finie —, et la dictée continue d'observer. Un repli sur les libellés cliquait, en pleine génération,
        // le premier « Copier le code » de la réponse : le seul bloc de code
        // s'insérait au curseur à la place du texte, sans que rien ne le dise.
        copierLaReponse(selParent, selCopier, selReponse) {
          if (!selCopier) return { ok: false, raison: 'pas de repère' };
          if (selParent) {
            let parents = [];
            try { parents = [...document.querySelectorAll(selParent)]; } catch (e) {}
            const vus = parents.filter((p) => p.getClientRects().length > 0);
            const liste = vus.length ? vus : parents;
            // Le dernier : un fil neuf n'a qu'une réponse, mais un
            // rechargement qui n'aurait pas abouti en laisserait plusieurs.
            let bouton = null;
            if (liste.length) {
              try { bouton = liste[liste.length - 1].querySelector(selCopier); }
              catch (e) { bouton = null; }
            }
            if (!bouton) return { ok: false, raison: 'paire absente' };
            bouton.click();
            return { ok: true, voie: 'paire' };
          }

          // Sans bloc, le repère est cherché autour de la dernière réponse,
          // là où il est seul (cf. `copierAutour`). C'est ce chemin que la
          // calibration automatique éprouve quand aucun bloc ne se laisse
          // désigner.
          const derniere = derniereReponse(selReponse);
          if (!derniere) return { ok: false, raison: 'pas de réponse' };
          const bouton = copierAutour(derniere, selCopier);
          if (!bouton) return { ok: false, raison: 'repère absent ou ambigu' };
          bouton.click();
          return { ok: true, voie: 'repere' };
        },

        // Le message est-il parti ? `cliquer` ne le dit pas : un bouton
        // désactivé, ou un clic avalé par l'éditeur, rend ok quand même. Ce
        // que la zone porte encore — `null` quand elle est absente, ce qui ne
        // prouve rien —, et si ChatGPT répond déjà.
        depart(selecteur, avant) {
          const zone = this.lire(selecteur);
          return { ok: true, zone: zone.ok ? zone.texte : null,
                   repond: document.querySelectorAll(REPONSES).length > avant
                           || generationEnCours() };
        },

        // Où en est la réponse attendue ?
        //
        // Sans aucun repère appris, pour les modules qui n'ont rien à
        // rapatrier mais doivent attendre la fin — faire lire à haute voix un
        // texte encore en train de s'écrire n'aurait pas de sens. `avant` est
        // le nombre de réponses relevé à l'envoi : tant qu'il n'a pas augmenté,
        // la dernière réponse est celle d'avant, et elle est finie depuis
        // longtemps. Le texte est rendu pour que Swift juge de sa stabilité.
        etatReponse(avant) {
          const reponses = document.querySelectorAll(REPONSES);
          const enCours = generationEnCours();
          if (reponses.length <= avant) return { ok: true, nouvelle: false, enCours };
          const t = reponses[reponses.length - 1].innerText || '';
          return { ok: true, nouvelle: true, enCours,
                   texte: t.replace(/\u00a0/g, ' ').trim() };
        },

        // Clique un bouton, éventuellement cadré dans un bloc.
        //
        // Le cadrage sert quand la page en contient plusieurs exemplaires — un
        // par message. Sans cadrage, on prend le dernier visible : c'est le cas
        // d'un élément de menu, que la page pose ailleurs dans le document et
        // qui n'existe qu'un à la fois.
        cliquerBouton(selParent, selBouton) {
          if (!selBouton) return { ok: false, raison: 'pas de sélecteur' };
          let candidats = [];
          try {
            if (selParent) {
              const blocs = [...document.querySelectorAll(selParent)]
                .filter((b) => b.getClientRects().length > 0);
              const bloc = blocs[blocs.length - 1];
              candidats = bloc ? [...bloc.querySelectorAll(selBouton)] : [];
            } else {
              candidats = [...document.querySelectorAll(selBouton)];
            }
          } catch (e) { return { ok: false, raison: String(e) }; }
          const vus = candidats.filter((b) => b.getClientRects().length > 0);
          const cible = (vus.length ? vus : candidats).pop();
          if (!cible) return { ok: false, raison: 'introuvable' };
          cible.click();
          return { ok: true };
        },

        // La **dernière** réponse de la conversation.
        //
        // La dernière et non la première : un fil neuf n'en contient qu'une,
        // mais rien ne garantit qu'un rechargement ait abouti, et lire la
        // première rendrait alors la réponse d'avant sans que rien ne le
        // signale.
        //
        // Par `derniereReponse` : le filet pour qui n'a pas de repère, et
        // pour qui en a un, « introuvable » tant qu'il ne trouve rien. Le
        // filet prenait sinon, avant que la réponse n'apparaisse, le message
        // de l'utilisateur — et deux secondes et demie de stabilité le
        // faisaient rendre comme la réponse.
        lireReponse(selecteur) {
          const derniere = derniereReponse(selecteur);
          if (!derniere) return { ok: false, raison: 'introuvable' };
          const t = derniere.innerText || '';
          return { ok: true, texte: t.replace(/\u00a0/g, ' ').trim() };
        },

        // Ce que la page affiche avant qu'on lui demande quelque chose : ses
        // alertes et ses échecs écrits, et le nombre de réponses de ChatGPT.
        releve() {
          return { ok: true,
                   alertes: [...alertesVisibles(), ...echecsEcrits()],
                   reponses: document.querySelectorAll(REPONSES).length };
        },

        // L'erreur que ChatGPT affiche lui-même.
        //
        // Sans la lire, un échec annoncé en toutes lettres dans la page se
        // traduisait par une attente muette de plusieurs minutes, la barre
        // bloquée sur « Transcription… », sans autre issue que de quitter
        // l'application.
        //
        // `connues` est le relevé fait avant la demande : ce qui y figure
        // n'est pas une réponse à cette demande-ci, et n'interrompt rien. Une
        // bannière permanente reste donc muette.
        //
        // Un échec **reconnu** — un motif, apparu depuis le relevé — compte
        // toujours, et `reconnue` le dit. Une alerte nouvelle qu'aucun motif
        // ne connaît — un plafond atteint à l'instant, formulé dans n'importe
        // quelle langue — ne compte que si `nouvelles` le demande ; et, quand
        // `avant` est donné (le nombre de réponses à l'envoi), seulement si
        // ChatGPT ne répond pas : aucune réponse nouvelle, aucune génération
        // en cours. Une bannière « limite bientôt atteinte » apparue pendant
        // que la réponse s'écrit ne dit rien de cette réponse ; la prendre
        // pour un refus faisait jeter une réponse juste.
        erreur(connues, nouvelles, avant) {
          const deja = new Set(connues || []);
          for (const t of alertesVisibles()) {
            if (!deja.has(t) && MOTIFS_ECHEC.test(t)) {
              return { ok: true, message: t, reconnue: true };
            }
          }
          for (const t of echecsEcrits()) {
            if (!deja.has(t)) return { ok: true, message: t, reconnue: true };
          }
          if (!nouvelles) return { ok: true, message: '' };
          if (avant >= 0 && (document.querySelectorAll(REPONSES).length > avant
                             || generationEnCours())) {
            return { ok: true, message: '' };
          }
          for (const t of alertesVisibles()) {
            if (!deja.has(t)) return { ok: true, message: t, reconnue: false };
          }
          return { ok: true, message: '' };
        },

        // Réduire la page à sa seule pastille d'enregistrement.
        //
        // La barre ne doit montrer que ce qui se passe : ChatGPT écoute, puis
        // transcrit. Tout le reste — la colonne des conversations, l'en-tête,
        // les suggestions sous le champ — n'a rien à y faire et prenait
        // l'essentiel de la place.
        //
        // Les sélecteurs sont des noms de balises, pas des classes : celles de
        // ChatGPT sont générées et changent à chaque déploiement, `nav` et
        // `header` non. Un décor qui résisterait au masquage serait laid, pas
        // cassé — c'est la dégradation qu'on veut.
        compacter(actif, selecteur) {
          const ID = 'relais-compact';
          document.getElementById(ID)?.remove();
          if (!actif) return { ok: true };
          const style = document.createElement('style');
          style.id = ID;
          style.textContent = `
            nav, aside, header { display: none !important; }
            main { padding: 0 !important; }
            form { margin: 0 !important; }
            body { overflow: hidden !important; }
            /* Les suggestions sous le champ — « Créer une image », « Écrire ou
               modifier » — débordaient dans la bande et la déséquilibraient.
               Elles sont les frères qui suivent le formulaire. */
            main form ~ * { display: none !important; }
          `;
          document.head.appendChild(style);
          const el = trouver('composeur', selecteur);
          // La pastille remplace la zone de saisie pendant l'écoute : on vise
          // le bloc qui les porte l'une et l'autre, pour que le cadrage tienne
          // dans les deux états.
          const bloc = el ? (el.closest('form') || el.parentElement || el) : null;
          // Centré dans les deux sens : la bande est plus étroite que la page,
          // et un cadrage vertical seul laissait la pastille décalée à gauche.
          if (bloc) bloc.scrollIntoView({ block: 'center', inline: 'center' });
          return { ok: true };
        },

        // Connecté ou non, et enregistrement en cours ou non.
        //
        // Le point qui avait été manqué : pendant la dictée, ChatGPT retire la
        // zone de saisie du DOM et la remplace par la barre d'onde. Se fier à
        // sa seule présence faisait donc conclure « déconnecté » exactement
        // pendant qu'on dictait.
        //
        // Le critère est donc élargi : on est dans l'application dès qu'un de
        // ses éléments est là — zone de saisie, micro, ou bouton d'arrêt —
        // et qu'on n'est pas sur un écran d'authentification. Un cookie serait
        // plus direct mais son nom est un détail d'implémentation d'OpenAI,
        // qui n'a rien promis à personne à son sujet.
        etat(selMicro, selStop, selComposeur) {
          // Par le repère appris, et non par « une zone éditable quelconque » :
          // une conversation qui contient un document produit par ChatGPT en
          // offre une seconde, et la page se déclarait alors « pas en train
          // d'enregistrer » pendant qu'elle enregistrait.
          const zone = trouver('composeur', selComposeur);
          const composeur = !!zone && zone.getClientRects().length > 0;
          const stop = !!trouver('stop', selStop);
          const micro = !!trouver('micro', selMicro);

          const chemin = location.pathname || '';
          const auth = /^\/auth\b/.test(chemin)
            || /^\/(login|log-in)\b/.test(chemin)
            || location.hostname.startsWith('auth.');

          // La preuve de non-connexion, et non la preuve de connexion.
          //
          // Le critère était la présence de la zone de saisie, du micro ou du
          // bouton d'arrêt. Or ChatGPT affiche une zone de saisie **et** un
          // micro à qui n'est pas connecté : la page d'accueil déconnectée
          // satisfaisait donc le test, et l'application sautait droit au
          // calibrage en annonçant « vous êtes connecté » devant un écran qui
          // proposait « Se connecter ».
          //
          // Un bouton de connexion, lui, ne s'affiche jamais une fois la
          // session ouverte. C'est une preuve négative, et c'est ce qui la rend
          // fiable : on ne peut pas la confondre avec un état transitoire.
          //
          // Reconnu d'abord à sa structure, qui ne dépend d'aucune langue. Lu
          // à son libellé, il n'était connu qu'en français et en anglais — et
          // un compte réglé dans une autre langue passait pour connecté devant
          // l'écran même qui lui proposait de se connecter. Deux signes : un
          // lien vers les pages de connexion, celles-là mêmes que `auth`
          // reconnaît à leur adresse ; ou un élément que la page nomme
          // connexion ou inscription dans son `data-testid`, écrit pour ses
          // propres tests et donc jamais traduit. Le libellé reste en repli.
          //
          // Les pages de connexion **de ChatGPT** seulement : son propre
          // domaine, ou son serveur d'authentification. Un lien vers le
          // `/signup` de n'importe quel site passait pour un bouton de
          // connexion — et une réponse qui en citait un suffisait à déclarer
          // déconnectée une session ouverte, à chaque appui.
          const versConnexion = (a) => {
            try {
              const u = new URL(a.href, location.href);
              if (/log-?out|sign-?out/i.test(u.pathname)) return false;
              const serveurAuth = /^auth[^.]*\./.test(u.hostname)
                && /(^|\.)(openai|chatgpt)\.com$/.test(u.hostname);
              return serveurAuth || (u.origin === location.origin
                && /^\/(auth\/)?(log-?in|sign-?up)\b/i.test(u.pathname));
            } catch (e) { return false; }
          };
          // Au début du nom seulement : une offre d'abonnement affichée à qui
          // est connecté peut fort bien contenir « signup » plus loin.
          const nommeConnexion = (el) =>
            /^(log-?in|sign-?up)\b/i.test(el.getAttribute('data-testid') || '');
          // Le libellé, sur les boutons seulement. Un lien de la colonne
          // latérale porte le titre d'une conversation, écrit par elle
          // (« Connexion SSH au serveur », « Login page design ») : lu comme
          // une invite, il déclarait déconnectée une session ouverte, à chaque
          // appui, tant que ce titre restait à l'écran. Un lien vers la
          // connexion se reconnaît déjà à son adresse.
          const invite = /^(se connecter|connexion|log ?in|sign ?up|s'inscrire|inscription)/i;
          let deconnecte = false;
          for (const el of document.querySelectorAll('button, a')) {
            if (el.getClientRects().length === 0) continue;
            // Rien de ce qu'écrit la conversation : un message peut porter un
            // lien ou un libellé « Sign up » sans que la page, elle, demande
            // quoi que ce soit — la même exclusion que `generationEnCours`.
            if (el.closest('article, [data-message-author-role]')) continue;
            if ((el.tagName === 'A' && el.hasAttribute('href') && versConnexion(el))
                || nommeConnexion(el)
                || (el.tagName === 'BUTTON' && invite.test((el.innerText || '').trim()))) {
              deconnecte = true;
              break;
            }
          }

          return {
            ok: true,
            url: location.href,
            // La page porte-t-elle une conversation ? C'est ce qui décide, une
            // fois la dictée finie, s'il faut en ouvrir une neuve pour la
            // prochaine ou s'il suffit de vider la zone de saisie.
            //
            // Dans un projet aussi — `/g/<projet>/c/<id>` —, qui est justement
            // le point de départ que les réglages recommandent. Ne reconnaître
            // que `/c/…` y laissait le fil ouvert d'une dictée à l'autre, et le
            // contexte s'y accumulait.
            conversation: /^(\/g\/[^/]+)?\/c\/[^/]+/.test(chemin),
            connecte: !auth && !deconnecte && (composeur || stop || micro),
            deconnecte,
            // La zone absente *et* l'arrêt présent : la page écoute.
            enregistrement: !composeur && stop,
            composeur,
            // Sans condition sur la zone de saisie : elle existe aussi pour
            // qui n'est pas connecté, et l'exiger absente faisait attendre
            // l'expiration du délai avant de conclure ce qu'on savait déjà.
            authentification: auth || deconnecte,
          };
        },

        // Le clic n'est pas intercepté : il atteint la page. Sans quoi
        // désigner le bouton d'arrêt serait impossible, puisqu'il n'existe
        // qu'une fois l'enregistrement démarré.
        calibrer(genre) {
          return new Promise((resolve) => {
            const surClic = (ev) => {
              // Seuls les clics de la main comptent.
              //
              // `isTrusted` est faux pour tout événement produit par du code —
              // et Caspr en produit : c'est ainsi qu'il pilote la page. Sans ce
              // filtre, une dictée lancée pendant une calibration lui faisait
              // enregistrer les boutons que Caspr venait de cliquer lui-même,
              // décalés d'un cran, et la calibration devenait silencieusement
              // fausse : le micro pointait sur la zone de texte.
              //
              // Une barrière logique empêche les deux flux de se croiser ;
              // celle-ci rend l'accident impossible même si elle cédait.
              if (!ev.isTrusted) return;

              // Un clic hors sujet ne compte pas — on continue d'écouter.
              //
              // À l'étape du bouton d'envoi, on demande d'abord d'écrire
              // quelque chose : le premier clic de l'utilisateur tombe donc
              // dans la zone de texte, et il était retenu comme s'il désignait
              // le bouton. La calibration passait à l'étape suivante en ayant
              // appris la zone de saisie à la place de la flèche bleue.
              //
              // Ignorer plutôt que refuser : on ne peut pas prévenir de ce
              // qu'on n'a pas demandé, et l'utilisateur cliquera le bon
              // élément juste après, ce qui est exactement ce qu'on attend.
              const el = ev.target.closest(CLIQUABLE[genre] || '*');
              if (!convient(genre, el)) return;

              terminer();
              resolve({ ok: true,
                        selecteur: selecteurStable(el, genre),
                        parent: selecteurAncetre(el) });
            };
            const terminer = () => {
              document.removeEventListener('click', surClic, true);
              window.__relaisAbandon = null;
            };
            // De quoi renoncer depuis Swift.
            //
            // Sans cela, une calibration qu'on abandonne — la fenêtre qu'on
            // ferme, un imprévu — laissait cette promesse attendre un clic qui
            // ne viendrait jamais. L'appel Swift restait suspendu, le parcours
            // se croyait en cours, et l'application devenait inutilisable
            // jusqu'à son redémarrage. Une attente sans issue n'est pas une
            // attente, c'est un blocage.
            window.__relaisAbandon = () => {
              terminer();
              resolve({ ok: false, raison: 'abandon' });
            };
            document.addEventListener('click', surClic, true);
          });
        },

        // Les candidats de la calibration automatique pour un repère, à
        // éprouver dans l'ordre.
        //
        // Tirés du filet, dans son ordre : le `data-testid` d'abord, écrit
        // par la page pour ses propres tests et donc jamais traduit, puis les
        // libellés. Seuls restent les éléments visibles, du bon genre, qui
        // n'ouvrent pas de menu, et qui portent un repère où ils sont seuls
        // (cf. `repereUnique`). Aucun n'est cliqué ici : c'est Swift qui
        // éprouve, un par un, et s'arrête au premier dont l'effet se voit.
        candidats(cible) {
          const genre = GENRE[cible];
          const liste = [];
          for (const s of (HEURISTIQUES[cible] || [])) {
            let els = [];
            try { els = [...document.querySelectorAll(s)]; } catch (e) { continue; }
            for (const el of els) {
              if (!visible(el) || !convient(genre, el)) continue;
              if (genre === 'bouton' && ouvreUnMenu(el)) continue;
              const sel = repereUnique(el, document, genre);
              if (sel && !liste.includes(sel)) liste.push(sel);
            }
          }
          return { ok: true, candidats: liste };
        },

        // Les candidats pour le bouton « copier » de la **dernière** réponse.
        //
        // Cherchés en remontant depuis elle, et non dans tout le document :
        // la page pose un bouton « copier » sous chaque message, celui de
        // l'utilisateur compris. Au premier niveau qui en contient, il doit y
        // en avoir un seul — une réponse qui porte un bloc de code en a un de
        // plus, et deviner lequel est celui du tour, c'est ce qui s'est
        // trompé chaque fois qu'on l'a essayé.
        //
        // Avec le bloc qui le porte quand il s'en trouve un sans ambiguïté
        // (cf. `paireCopier`). Sinon sans bloc, et seulement avec un repère
        // que `copierAutour` — la règle même de la dictée — ramène à ce
        // bouton-là et à nul autre : un repère qui en désigne plusieurs
        // laisserait la page choisir, et la preuve porterait sur son choix,
        // pas sur le repère. Swift éprouve l'un ou l'autre par
        // `copierLaReponse`, comme la dictée le suivra.
        //
        // `selReponse` : le repère de la réponse que la dictée consultera,
        // pour partir de la même réponse qu'elle.
        //
        // Le filet d'abord, les niveaux ensuite : le `data-testid` du bouton
        // du tour, un cran plus haut, l'emporte sur un libellé « Copier le
        // code » posé dans la réponse même, qui copierait le seul bloc de
        // code — non vide, étranger au message envoyé, et donc pris pour une
        // preuve.
        candidatsCopier(selReponse) {
          const derniere = derniereReponse(selReponse);
          if (!derniere) return { ok: false, raison: 'pas de réponse' };
          const liste = [];
          for (const s of HEURISTIQUES.copier) {
            let noeud = derniere;
            for (let niveau = 0; niveau < 6 && noeud; niveau++) {
              let els = [];
              try { els = [...noeud.querySelectorAll(s)]; } catch (e) { break; }
              const boutons = els.filter((b) => visible(b) && convient('bouton', b)
                                                && !ouvreUnMenu(b));
              if (boutons.length) {
                if (boutons.length === 1) {
                  const el = boutons[0];
                  const seul = [...reperesPossibles(el), s]
                    .find((c) => copierAutour(derniere, c) === el);
                  const paire = paireCopier(el)
                    || (seul ? { selecteur: seul, parent: '' } : null);
                  if (paire && !liste.some((c) => c.selecteur === paire.selecteur
                                                  && c.parent === paire.parent)) liste.push(paire);
                }
                // Le premier niveau qui en contient décide : plus haut, on
                // entrerait dans les messages voisins.
                break;
              }
              noeud = noeud.parentElement;
            }
          }
          return { ok: true, candidats: liste };
        },

        // Efface le brouillon que ChatGPT garde en réserve.
        //
        // Vider la zone ne suffit pas : le texte non envoyé est conservé dans
        // le stockage local de la page et réinstallé au rechargement, parfois
        // même après qu'on l'a effacé à l'écran. On ne touche qu'aux clés qui
        // le désignent — la session, elle, vit dans les cookies et n'est pas
        // concernée.
        oublierBrouillon() {
          let retirees = 0;
          try {
            for (const cle of Object.keys(localStorage)) {
              if (/draft|composer/i.test(cle)) { localStorage.removeItem(cle); retirees++; }
            }
          } catch (e) { /* stockage inaccessible : on s'en passe */ }
          return { ok: true, retirees };
        },

        // Calibrer un bouton qui se cache peut-être dans un menu.
        //
        // « Lire à haute voix » est parfois directement sous la réponse, et
        // parfois derrière les trois points. On ne demande donc pas à
        // l'utilisateur de savoir lequel des deux cas est le sien : on écoute
        // ses clics, et l'on reconnaît celui qui ouvre un menu à ce qu'il le
        // déclare — `aria-haspopup` est posé par la page, pas deviné par nous.
        //
        // Le premier clic sur un ouvre-menu est retenu à part, et l'on continue
        // d'écouter ; le suivant est le bouton cherché. S'il n'y a pas de menu,
        // le premier clic est déjà le bon et l'on s'arrête là.
        calibrerAvecMenu() {
          return new Promise((resolve) => {
            let menu = null;
            const surClic = (ev) => {
              if (!ev.isTrusted) return;
              const el = ev.target.closest(CLIQUABLE.bouton);
              if (!convient('bouton', el)) return;
              const ouvreUnMenu = el.getAttribute('aria-haspopup')
                || el.getAttribute('aria-expanded') !== null;
              if (ouvreUnMenu && !menu) {
                menu = { selecteur: selecteurStable(el, 'bouton'),
                         parent: selecteurAncetre(el) };
                return;                      // on attend le vrai bouton
              }
              terminer();
              resolve({ ok: true,
                        selecteur: selecteurStable(el, 'bouton'),
                        parent: selecteurAncetre(el),
                        menu: menu ? menu.selecteur : '',
                        menuParent: menu ? menu.parent : '' });
            };
            const terminer = () => {
              document.removeEventListener('click', surClic, true);
              window.__relaisAbandon = null;
            };
            window.__relaisAbandon = () => {
              terminer();
              resolve({ ok: false, raison: 'abandon' });
            };
            document.addEventListener('click', surClic, true);
          });
        },

        // Fait renoncer une calibration en cours, s'il y en a une.
        abandonnerCalibration() {
          if (window.__relaisAbandon) { window.__relaisAbandon(); return { ok: true }; }
          return { ok: false };
        },
      };
    })();
    """#

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
