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
        case cliquer, lire, ecrire, encadrer, copierLaReponse, cliquerBouton
        case lireReponse, compacter, oublierBrouillon, candidats, candidatsCopier
        case guetter, abandonnerCalibration
        case marquer, instantane
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

      // Les conteneurs que ChatGPT nomme lui-même, et sur lesquels une chaîne
      // de position peut s'ancrer.
      //
      // `reperesPossibles` ne regarde que `data-testid`, l'identifiant et le
      // libellé d'accessibilité. Le rôle que ChatGPT écrit sur chaque message
      // n'en fait pas partie — alors que c'est l'attribut le plus durable de
      // toute la page, celui sur lequel le filet des réponses est déjà bâti.
      // Faute de le reconnaître, aucun ancêtre d'un paragraphe de réponse ne
      // pouvait servir d'ancre, et la chaîne restait une forme.
      const ANCRES = [REPONSES, '[data-message-author-role="user"]', '#prompt-textarea'];


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
        // Pas de filet pour « Lire à haute voix » : aucun chemin ne le
        // cherche sans repère — la dictée ne le clique que calibré (cf.
        // `RelaisSelecteurs.saitLire`), et l'automate ne l'essaie jamais.
      };

      // Dessiné à l'écran. Une page jamais affichée n'a rien de dessiné :
      // WebKit ne la dispose pas, et la nôtre naît hors champ (cf. `trouver`).
      const vu = (el) => el.getClientRects().length > 0;
      const visible = (el) => !!el && el.isConnected && vu(el);
      // Le dernier des visibles s'il y en a, sinon le dernier de tous : sur
      // une page jamais affichée, aucun ne l'est, et le dernier de tous reste
      // le bon. Une seule règle pour tout ce qui cherche « le dernier » — le
      // bloc de « copier », le bouton cadré, la dernière réponse.
      const dernierVu = (els) => { const vus = els.filter(vu); return (vus.length ? vus : els).pop() || null; };

      // Tout ce qui répond au sélecteur. Un sélecteur invalide — un repère
      // appris d'une page qui a changé — ne désigne rien, et ne lève rien.
      const tous = (selecteur, portee = document) => {
        try { return [...portee.querySelectorAll(selecteur)]; } catch (e) { return []; }
      };

      const champ = (el) => el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';

      // L'espace insécable vient du rendu, pas de la dictée : le laisser
      // ferait arriver des U+00A0 dans le code et les terminaux.
      const net = (t) => (t || '').replace(/\u00a0/g, ' ').trim();

      const texteDe = (el) => net(champ(el) ? el.value : el.innerText);

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

      // Un bouton : ce que `CLIQUABLE` dit cliquable, une seule règle.
      const convient = (genre, el) => {
        if (!el) return false;
        if (genre === 'saisie') return el.isContentEditable || champ(el);
        return genre !== 'bouton' || el.matches(CLIQUABLE.bouton);
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

      // Le premier des repères de l'élément qui passe l'épreuve `garde` ; ''
      // si aucun. Deux épreuves, selon qui a trouvé l'élément.
      const premierRepere = (el, garde) => reperesPossibles(el).find(garde) || '';

      // Un clic de l'utilisateur : le repère ne vaut que s'il retrouve
      // l'élément cliqué.
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
      const leRetrouve = (el, genre) => (c) => tous(c).filter((x) => convient(genre, x)).includes(el);

      // L'automate : une adresse, pas une ressemblance — l'élément doit être
      // le **seul** à répondre au repère.
      //
      // Retrouver l'élément ne prouverait rien ici : l'automate l'a trouvé
      // *par* ce sélecteur, la question contient sa réponse. Ce qui dit
      // quelque chose, c'est l'unicité. Le reste de la preuve est dans
      // l'effet, que Swift observe. Avec un genre, selon la règle de
      // `trouver` — connectés, et du bon genre. Sans genre, tout ce qui
      // répond compte : c'est la règle de la paire « copier », où la page
      // prend le premier élément du bloc sans rien filtrer.
      //
      // Jamais le sélecteur du filet qui a trouvé l'élément : ceux qui sont
      // des adresses (`data-testid`, `#prompt-textarea`), l'élément les porte
      // et `reperesPossibles` les propose déjà ; les autres
      // (`div[contenteditable]`, `textarea`, `aria-label*=`) sont des
      // ressemblances. Seule sur l'accueil vide, une zone éditable
      // quelconque passait la preuve — puis, la zone de saisie retirée
      // pendant l'enregistrement, le repère rendait le canevas d'à côté au
      // lieu de dire « absent ».
      const seulA = (el, portee, genre) => (c) => {
        const retenus = tous(c, portee).filter((x) => !genre || (x.isConnected && convient(genre, x)));
        return retenus.length === 1 && retenus[0] === el;
      };

      // Un bouton qui ouvre un menu, la page le déclare (cf.
      // `guetter`). L'automate ne le clique jamais : le menu « … »
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
            if (dernierVu(tous(selParent)) !== n) continue;
            const selecteur = premierRepere(el, seulA(el, n, null));
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
        // ## Le rôle que ChatGPT écrit passe avant le repère appris
        //
        // `REPONSES` est plus sûr que tout ce qu'on pourrait apprendre : il ne
        // désigne que des réponses, jamais le message de l'utilisateur. La
        // mise en garde ci-dessus visait le second filet, `article`, qui lui
        // ramène n'importe quel message — elle ne vaut pas pour celui-ci.
        //
        // Le repère appris, lui, n'est **jamais réappris** : `.reponse` ne
        // figure pas dans `RelaisEtape.parcoursManuel`, qui va du micro à
        // « copier » sans passer par la réponse. Un calibrage ancien y survit
        // donc indéfiniment, et aucune recalibration ne le corrige. Celui
        // relevé sur une machine était une chaîne de position : « copier » y
        // était refusé à chaque essai, avec un message qui accusait le clic
        // qu'on venait de faire au lieu d'un repère vieux de plusieurs
        // versions.
        //
        // C'est aussi ce que fait déjà `copierPret`, qui compte les réponses
        // par `REPONSES` sans consulter le repère : deux endroits répondaient à
        // « laquelle est la dernière réponse » par deux règles différentes.
        const nommees = tous(REPONSES);
        if (nommees.length) return dernierVu(nommees);
        const listes = selReponse ? [tous(selReponse)] : HEURISTIQUES.reponse.map((s) => tous(s));
        return dernierVu(listes.find((l) => l.length) || []);
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
          const boutons = tous(selCopier, noeud).filter((b) => visible(b) && convient('bouton', b));
          if (boutons.length) return boutons.length === 1 ? boutons[0] : null;
          noeud = noeud.parentElement;
        }
        return null;
      }

      // Le bouton « copier » que la dictée cliquerait, sans le cliquer : la
      // paire — le dernier bloc, le premier bouton dedans —, ou le repère
      // seul autour de la dernière réponse (cf. `copierLaReponse`). Une seule
      // règle pour le clic et pour dire qu'il est possible (`copierPret`).
      function boutonCopier(selParent, selCopier, selReponse) {
        if (!selCopier) return { raison: 'pas de repère' };
        if (selParent) {
          // Le dernier : un fil neuf n'a qu'une réponse, mais un
          // rechargement qui n'aurait pas abouti en laisserait plusieurs.
          const bloc = dernierVu(tous(selParent));
          const bouton = bloc && tous(selCopier, bloc)[0];
          return bouton ? { bouton, voie: 'paire' } : { raison: 'paire absente' };
        }
        // Sans bloc, le repère est cherché autour de la dernière réponse,
        // là où il est seul. C'est ce chemin que la calibration automatique
        // éprouve quand aucun bloc ne se laisse désigner.
        const derniere = derniereReponse(selReponse);
        if (!derniere) return { raison: 'pas de réponse' };
        const bouton = copierAutour(derniere, selCopier);
        return bouton ? { bouton, voie: 'repere' } : { raison: 'repère absent ou ambigu' };
      }

      // Le « copier » que l'utilisateur a désigné, appris seulement s'il est
      // celui de la dernière réponse (cf. `guetter`) : dans le plus petit
      // bloc qui les porte tous deux, aucun autre message. Sinon un repère
      // vide — un refus, que Swift explique.
      //
      // Quatre façons de refuser, et elles n'appellent pas le même geste. Elles
      // rendaient toutes le même repère vide, et Swift n'avait qu'une phrase à
      // offrir : « ce n'est pas le bouton de la réponse ». Opposée à un clic
      // juste, elle envoie chercher une erreur là où il n'y en a pas — trois
      // tours de diagnostic y sont passés. Chacune dit maintenant laquelle.
      // Ce que la page offre autour du bouton cliqué, quand on n'y trouve pas
      // de réponse.
      //
      // `REPONSES` est le seul pari écrit en dur de ce module, alors que tout
      // le reste s'apprend. Le jour où ChatGPT le dément — le 4 octobre 2026 —
      // la page n'offre plus « aucune réponse » et il n'y avait aucun moyen de
      // le constater sans deviner. Les attributs des ancêtres du bouton le
      // disent en une ligne, et nomment du même coup ce qui devrait prendre la
      // relève.
      function inventaire(el) {
        // Sous `try` entier : c'est un diagnostic, appelé **depuis un chemin
        // d'échec**. S'il lève, il emporte le refus qu'il devait expliquer et
        // la calibration rend `null` au lieu d'une raison — ce qu'un test a
        // attrapé sur un document qui n'expose pas `attributes`.
        try { return inventaireOuLeve(el); } catch (e) { return 'page illisible'; }
      }

      function inventaireOuLeve(el) {
        const vus = [];
        let n = el;
        for (let i = 0; i < 10 && n && n.nodeType === 1; i++) {
          const noms = [...n.attributes]
            .filter((a) => a.name.startsWith('data-') || a.name === 'role')
            .map((a) => (a.value && a.value.length < 24 ? a.name + '=' + a.value : a.name));
          if (noms.length) vus.push(n.tagName.toLowerCase() + '[' + noms.join(' ') + ']');
          n = n.parentElement;
        }
        const compte = 'article:' + tous('article').length
          + ' role:' + tous('[data-message-author-role]').length;
        return compte + (vus.length ? ' — ' + vus.join(' < ') : ' — aucun attribut data-');
      }

      function copierDesigne(el, derniere) {
        const refus = (raison) => ({ ok: true, selecteur: '', parent: '', raison });
        if (!derniere) return refus('aucune réponse trouvée dans la page — ' + inventaire(el));
        let tour = el;
        while (tour && !tour.contains(derniere)) tour = tour.parentElement;
        if (!tour) return refus('ce bouton et la dernière réponse n\u2019ont aucun bloc commun');
        const autres = tous('[data-message-author-role], article', tour)
          .filter((m) => !m.contains(derniere) && !derniere.contains(m));
        if (autres.length) {
          return refus('ce bouton n\u2019est pas sous la dernière réponse : le plus '
                       + 'petit bloc qui les réunit porte ' + autres.length
                       + ' autre(s) message(s)');
        }
        const repere = repereCopier(el, derniere);
        // `ok: true` : `repereCopier` ne rend que le couple repère/bloc.
        return repere ? { ok: true, ...repere }
                      : refus('aucun repère stable ne ramène à ce bouton seul');
      }

      // Le repère d'un « copier » tel que la dictée le retrouvera, pour les
      // deux parcours : la paire (cf. `paireCopier`), sinon un repère — parmi
      // les siens et `autres` — que `copierAutour` ramène à ce seul bouton.
      function repereCopier(el, derniere, autres = []) {
        const seul = [...reperesPossibles(el), ...autres].find((c) => copierAutour(derniere, c) === el);
        return paireCopier(el) || (seul ? { selecteur: seul, parent: '' } : null);
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
      // remaniement, mais une calibration automatique le réapprend.
      function selecteurStable(el, genre, cible) {
        // ## La réponse, c'est le tour — pas le paragraphe cliqué
        //
        // On désigne « la réponse de ChatGPT » en cliquant dedans, donc sur un
        // paragraphe. Mais ce que la dictée veut, c'est le message entier : le
        // bouton « copier » se cherche autour de lui (`copierDesigne`), et un
        // paragraphe exclut le reste de la réponse.
        //
        // Surtout, un paragraphe n'a rien qui le nomme : on en tirait une
        // chaîne de position, éprouvée sur un fil neuf où elle ne désignait
        // encore que lui. Au troisième message elle répondait ailleurs, et le
        // refus tombait sur un bouton pourtant bien désigné — « le premier
        // message fonctionne, ensuite ça refait le bug ».
        //
        // Le tour, lui, porte le rôle que ChatGPT écrit sur chaque message.
        // Il n'y a donc rien à apprendre ici : la bonne réponse est connue, et
        // elle vaut pour toute la conversation. Rendu avant l'épreuve de
        // `leRetrouve`, qui demanderait de retrouver l'élément cliqué —
        // justement celui qu'on remplace, et à dessein.
        if (cible === 'reponse' && el.closest(REPONSES)) return REPONSES;
        const repere = premierRepere(el, leRetrouve(el, genre));
        if (repere) return repere;
        const chaine = chaineAncree(el);
        return designeBien(el, genre, cible, chaine) ? chaine : '';
      }

      // La chaîne de position de l'élément, **ancrée** dès qu'un ancêtre porte
      // un repère solide.
      //
      // Sans ancre, `div:nth-of-type(1) > … > p` n'est pas une adresse : c'est
      // une *forme*, et `querySelectorAll` la fait répondre partout où cette
      // forme se retrouve dans le document — y compris sous les messages de
      // l'utilisateur.
      //
      // Mesuré sur une calibration réelle : la zone de saisie et la réponse
      // avaient toutes deux été retenues ainsi. Conséquences, et il a fallu les
      // journaux pour les relier à cette ligne — « zone non » à chaque relevé,
      // la dictée attendant sans fin une zone qu'aucun élément trouvé n'était ;
      // et « Pas ce bouton-là » opposé à un bouton « copier » pourtant
      // correctement désigné, parce que `derniereReponse` prend le dernier du
      // document et tombait sur un paragraphe d'un autre tour.
      //
      // Préfixée d'un ancêtre retrouvable, la même chaîne redevient une
      // adresse : « ce nœud-là, dans ce bloc-ci ».
      function chaineAncree(el) {
        const parts = [];
        let n = el;
        for (let i = 0; i < 6 && n && n.nodeType === 1; i++) {
          if (!idEngendre(n.id)) { parts.unshift('#' + esc(n.id)); return parts.join(' > '); }
          if (n !== el) {
            const valide = leRetrouve(n, 'bloc');
            const ancre = premierRepere(n, valide) || ANCRES.find(valide);
            if (ancre) { parts.unshift(ancre); return parts.join(' > '); }
          }
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

      // Le repère construit désigne-t-il vraiment ce qu'on croit ?
      //
      // Les repères d'attribut sont éprouvés depuis longtemps (`leRetrouve`) ;
      // la chaîne de position, elle, était retenue sans que personne demande
      // jamais ce qu'elle désignait. Un repère non éprouvé n'échoue pas tout de
      // suite : il échoue des jours plus tard, dans une attente muette.
      //
      // La réponse demande davantage que « retrouver l'élément ». La dictée en
      // prend **le dernier du document** (`derniereReponse`) : un repère qui
      // répond aussi sous le message de l'utilisateur la fait partir du mauvais
      // tour. Le rôle que ChatGPT écrit sur chaque message tranche — et quand
      // la page ne l'écrit nulle part, on n'exige rien de plus : on ne bloque
      // pas une calibration sur une forme de page qu'on ne reconnaît pas.
      function designeBien(el, genre, cible, sel) {
        if (!sel || !leRetrouve(el, genre)(sel)) return false;
        if (cible !== 'reponse') return true;
        // ## Pourquoi la réponse ne se contente pas d'être retrouvée
        //
        // La dictée en prend le **dernier** élément du document
        // (`derniereReponse`), dans une conversation qui s'allonge. Une forme
        // nue ne désigne donc pas la même chose au premier message et au
        // troisième : éprouvée sur un fil neuf — une seule réponse, aucun
        // paragraphe concurrent — elle passe, puis se met à répondre ailleurs.
        //
        // C'est ce qui a été mesuré : « le premier message fonctionne, ensuite
        // ça refait le bug ». La vérification d'un repère ne peut pas voir la
        // page de demain ; elle peut exiger une ancre, qui la rend inutile.
        //
        // Une ancre, donc, et aucun élément désigné sous un message de
        // l'utilisateur. Sans ancre possible, la calibration échoue en nommant
        // la cible — mieux qu'un repère qui marchera une fois.
        if (!sel.includes('[') && !sel.includes('#')) return false;
        return tous(sel).every((m) => !m.closest('[data-message-author-role="user"]'));
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
          const repere = premierRepere(n, leRetrouve(n, 'bloc'));
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
      // apparu depuis la marque (cf. `echecNouveau`).
      const MOTIFS_ECHEC = /n'a pas compris|pas compris|didn.t catch|try again|réessayer/i;
      const estEchec = (texte) => MOTIFS_ECHEC.test(texte);

      // Les textes des alertes affichées. `role="alert"` est un rôle
      // d'accessibilité normalisé, et non une classe générée.
      const alertesVisibles = () => tous('[role="alert"]').filter(vu)
        .map((el) => (el.innerText || '').trim())
        .filter((t) => t);

      // Les échecs écrits hors de toute alerte, pour les pages qui n'en posent
      // pas.
      //
      // Cherchés là où ils peuvent être seulement : le dernier tour de la
      // conversation, et le formulaire de la zone de saisie. Et lus sans
      // forcer la mise en page : `textContent` d'abord, qui ne dispose rien ;
      // `innerText` et la visibilité, qui recalculent la disposition, sur ce
      // seul qui ressemble à un échec. Lire `innerText` de chaque `div, span,
      // p` du tour, plusieurs fois par seconde, ralentissait la conversation
      // qu'on attendait justement de voir avancer.
      //
      // Dans ce tour, jamais le texte d'un message — ni ce qui le contient :
      // le parcours saute chaque message entier, et traverse sans les lire
      // les blocs qui en portent un. La réponse de ChatGPT peut dire « on
      // peut réessayer », la dictée envoyée « try again » : lus comme des
      // échecs, ils faisaient jeter une réponse juste, ou conclure au refus
      // avant même que ChatGPT ait répondu. Reste ce que la page dessine
      // autour du message, où elle pose ses propres avis d'échec. Un échec
      // écrit ailleurs n'est pas deviné : l'attente continue, et la touche de
      // dictée en sort.
      //
      // Ni la zone de saisie, pour la même raison : la transcription y revient
      // avant d'être un message. « Je n'ai pas compris, tu peux réessayer ? »,
      // dicté, y était lu comme un refus de ChatGPT, et la dictée échouait
      // sur les propres mots de l'utilisateur. Ni, là encore, les blocs qui
      // l'enveloppent : leur texte est celui de la zone. Les écarter de la
      // zone seule laissait le refus passer par eux ; un avis posé à côté de
      // la zone, lui, se lit toujours.
      const MESSAGE = '[data-message-author-role]';
      const PORTE = MESSAGE + ', [contenteditable="true"], textarea, input';
      const tri = (porteurs) => (el) =>
        el.matches(MESSAGE) || el.isContentEditable || champ(el)
          ? NodeFilter.FILTER_REJECT
          : !porteurs.has(el) && /^(DIV|SPAN|P)$/.test(el.tagName) ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_SKIP;
      const echecsEcrits = () => {
        const textes = [];
        for (const zone of [tous('article').pop(), tous('main form').pop()]) {
          if (!zone) continue;
          const porteurs = new Set();
          for (const m of tous(PORTE, zone)) {
            for (let n = m.parentElement; n && n !== zone; n = n.parentElement) porteurs.add(n);
          }
          const parcours = document.createTreeWalker(zone, NodeFilter.SHOW_ELEMENT, tri(porteurs));
          for (let el = parcours.nextNode(); el; el = parcours.nextNode()) {
            if (!estEchec(el.textContent)) continue;
            const t = (el.innerText || '').trim();
            if (t && t.length < 120 && estEchec(t) && vu(el)) textes.push(t);
          }
        }
        return textes;
      };

      // Le premier échec apparu depuis la marque (cf. `marquer`). Un échec
      // **reconnu** — un motif — compte toujours. Une alerte nouvelle
      // qu'aucun motif ne connaît — un plafond atteint à l'instant, formulé
      // dans n'importe quelle langue — est rendue aussi, et c'est Swift qui
      // juge si elle compte (cf. `RelaisVeille.refus`). Une bannière déjà là
      // à la marque reste muette.
      const echecNouveau = (marque) => {
        const deja = new Set(marque.echecs || []), nouveau = (t) => !deja.has(t);
        const alertes = alertesVisibles().filter(nouveau);
        const reconnu = alertes.find(estEchec) || echecsEcrits().find(nouveau);
        if (reconnu) return { texte: reconnu, reconnue: true };
        return alertes.length ? { texte: alertes[0], reconnue: false } : null;
      };

      // ChatGPT est-il en train d'écrire sa réponse ?
      //
      // Le bouton qui arrête la génération le dit sans calibration : il
      // n'existe que pendant l'écriture. Cherché dans le formulaire de la
      // zone de saisie, où la page le pose, et hors des messages, où elle
      // pose d'autres boutons. **Jamais l'arrêt de la dictée** : il porte les
      // mêmes libellés — « stop », « arrêt » —, et le prendre pour une
      // génération faisait croire que ChatGPT répondait pendant qu'on lui
      // parlait.
      // Les libellés de l'arrêt, sans son `data-testid` de dictée.
      const GENERATION = ['[data-testid="stop-button"]', ...HEURISTIQUES.stop.slice(1)];
      const generationEnCours = (zone, arretDictee) => {
        const formulaire = (zone && zone.closest('form')) || tous('main form').pop() || document;
        return GENERATION.some((s) => tous(s, formulaire).some((el) => el !== arretDictee
          && !el.matches('[data-testid*="speech"]') && !el.closest('article, ' + MESSAGE)
          && visible(el) && convient('bouton', el)));
      };

      // La page porte-t-elle une conversation ? C'est ce qui décide, une fois
      // la dictée finie, s'il faut en ouvrir une neuve pour la prochaine ou
      // s'il suffit de vider la zone de saisie.
      //
      // Dans un projet aussi — `/g/<projet>/c/<id>` —, qui est justement le
      // point de départ que les réglages recommandent. Ne reconnaître que
      // `/c/…` y laissait le fil ouvert d'une dictée à l'autre, et le
      // contexte s'y accumulait.
      const estConversation = (chemin) => /^(\/g\/[^/]+)?\/c\/[^/]+/.test(chemin || '');

      // Un écran d'authentification, à son adresse (`location`, ou ce qui en
      // a la forme).
      const estAuthentification = (lieu) => /^\/(auth|login|log-in)\b/.test(lieu.pathname || '')
        || (lieu.hostname || '').startsWith('auth.');

      // La preuve de non-connexion, et non la preuve de connexion.
      //
      // Le critère était la présence de la zone de saisie, du micro ou du
      // bouton d'arrêt. Or ChatGPT affiche une zone de saisie **et** un
      // micro à qui n'est pas connecté : la page d'accueil déconnectée
      // satisfaisait donc le test, et l'application sautait droit au
      // calibrage en annonçant « vous êtes connecté » devant un écran qui
      // proposait « Se connecter ». Un bouton de connexion, lui, ne s'affiche
      // jamais une fois la session ouverte : une preuve négative, qu'on ne
      // peut pas confondre avec un état transitoire.
      //
      // Reconnu d'abord à sa structure, qui ne dépend d'aucune langue. Lu à
      // son libellé, il n'était connu qu'en français et en anglais — et un
      // compte réglé dans une autre langue passait pour connecté devant
      // l'écran même qui lui proposait de se connecter. Deux signes : un lien
      // vers les pages de connexion, celles-là mêmes que `estAuthentification`
      // reconnaît à leur adresse ; ou un lien ou un bouton que la page nomme
      // connexion ou inscription dans son `data-testid`, écrit pour ses
      // propres tests et donc jamais traduit. Le libellé reste en repli.
      //
      // Les pages de connexion **de ChatGPT** seulement : son propre domaine,
      // ou son serveur d'authentification. Un lien vers le `/signup` de
      // n'importe quel site passait pour un bouton de connexion — et une
      // réponse qui en citait un suffisait à déclarer déconnectée une session
      // ouverte, à chaque appui.
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
      // Au début du nom seulement : une offre d'abonnement affichée à qui est
      // connecté peut fort bien contenir « signup » plus loin.
      const nommeConnexion = (el) => /^(log-?in|sign-?up)\b/i.test(el.getAttribute('data-testid') || '');
      // Le libellé, sur les boutons seulement. Un lien de la colonne latérale
      // porte le titre d'une conversation, écrit par elle (« Connexion SSH au
      // serveur », « Login page design ») : lu comme une invite, il déclarait
      // déconnectée une session ouverte, à chaque appui, tant que ce titre
      // restait à l'écran. Un lien vers la connexion se reconnaît déjà à son
      // adresse.
      const INVITE = "(se connecter|connexion|log ?in|sign ?up|s'inscrire|inscription)";
      const estInvite = (texte) => new RegExp('^' + INVITE, 'i').test(texte);
      // Les seuls candidats, présélectionnés par le moteur CSS : la page n'est
      // parcourue ni lue en entier à chaque relevé. La visibilité et le texte
      // rendu ne se demandent qu'à eux.
      const INVITES = ['a[href*="login" i]', 'a[href*="log-in" i]', 'a[href*="signup" i]',
        'a[href*="sign-up" i]', 'a[href*="//auth" i]', ':is(a, button)[data-testid^="log" i]',
        ':is(a, button)[data-testid^="sign" i]'].join(', ');
      const inviteDeConnexion = () => [...tous(INVITES),
          ...tous('button').filter((b) => new RegExp(INVITE, 'i').test(b.textContent))]
        // Rien de ce qu'écrit la conversation : un message peut porter un
        // lien ou un libellé « Sign up » sans que la page, elle, demande quoi
        // que ce soit.
        .some((el) => !el.closest('article, ' + MESSAGE) && vu(el)
          && ((el.tagName === 'A' && el.hasAttribute('href') && versConnexion(el))
              || nommeConnexion(el)
              || (el.tagName === 'BUTTON' && estInvite((el.innerText || '').trim()))));

      // Remplace le contenu de la zone de saisie — `delete` pour la vider (un
      // texte vide), `insertText` pour y écrire.
      //
      // Par `execCommand` et non en écrasant le DOM : le composeur est un
      // éditeur ProseMirror, dont l'état interne se désynchronise si on le
      // modifie dans son dos — le message partirait vide, ou un brouillon
      // effacé reviendrait à la frappe suivante.
      const remplacer = (selecteur, texte) => {
        const commande = texte ? 'insertText' : 'delete';
        const el = trouver('composeur', selecteur);
        if (!el) return { ok: false, raison: 'introuvable' };
        el.focus();
        let fait = false;
        try {
          document.execCommand('selectAll', false, null);
          fait = document.execCommand(commande, false, commande === 'delete' ? null : texte);
        } catch (e) { fait = false; }
        if (!fait) {
          if (champ(el)) el.value = texte;
          else el.textContent = texte;
        }
        return relacher(el);
      };

      // Rendre le focus. Le prendre était nécessaire — ProseMirror n'écrit ni
      // ne se vide autrement — mais le garder faisait de cette page le champ
      // focalisé du système, et la dictée s'écrivait ici au lieu de l'éditeur
      // de l'utilisateur.
      const relacher = (el) => {
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.blur();
        return { ok: true };
      };

      // Écoute les clics de l'utilisateur jusqu'à ce que `retenir` en garde
      // un — il rend alors ce que la calibration a appris, `null` sinon.
      //
      // Le clic n'est pas intercepté : il atteint la page. Sans quoi
      // désigner le bouton d'arrêt serait impossible, puisqu'il n'existe
      // qu'une fois l'enregistrement démarré.
      const ecouterLesClics = (retenir) => new Promise((resolve) => {
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
          const appris = retenir(ev);
          if (appris) terminer(appris);
        };
        const terminer = (resultat) => {
          document.removeEventListener('click', surClic, true);
          window.__relaisAbandon = null;
          resolve(resultat);
        };
        // De quoi renoncer depuis Swift (cf. `abandonnerCalibration`).
        //
        // Sans cela, une calibration qu'on abandonne — la fenêtre qu'on
        // ferme, un imprévu — laissait cette promesse attendre un clic qui
        // ne viendrait jamais. L'appel Swift restait suspendu, le parcours
        // se croyait en cours, et l'application devenait inutilisable
        // jusqu'à son redémarrage. Une attente sans issue n'est pas une
        // attente, c'est un blocage.
        window.__relaisAbandon = () => terminer({ ok: false, raison: 'abandon' });
        document.addEventListener('click', surClic, true);
      });

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
          return { ok: true, texte: texteDe(el) };
        },

        // Dépose un texte dans la zone de saisie, en remplaçant ce qui s'y
        // trouve ; vide, la vide. Les retours à la ligne du texte n'envoient
        // rien : seule une frappe sur Entrée le ferait, et on ne la simule pas.
        ecrire(selecteur, texte) { return remplacer(selecteur, texte); },

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
          return relacher(el);
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
        // réponse finie —, et la dictée continue d'observer. Un repli sur les
        // libellés cliquait, en pleine génération, le premier « Copier le
        // code » de la réponse : le seul bloc de code s'insérait au curseur à
        // la place du texte, sans que rien ne le dise.
        copierLaReponse(selParent, selCopier, selReponse) {
          const { bouton, voie, raison } = boutonCopier(selParent, selCopier, selReponse);
          if (!bouton) return { ok: false, raison };
          bouton.click();
          return { ok: true, voie };
        },

        // Clique un bouton, éventuellement cadré dans un bloc.
        //
        // Le cadrage sert quand la page en contient plusieurs exemplaires — un
        // par message. Sans cadrage, on prend le dernier visible : c'est le cas
        // d'un élément de menu, que la page pose ailleurs dans le document et
        // qui n'existe qu'un à la fois.
        cliquerBouton(selParent, selBouton) {
          if (!selBouton) return { ok: false, raison: 'pas de sélecteur' };
          const bloc = selParent ? dernierVu(tous(selParent)) : document;
          const cible = bloc && dernierVu(tous(selBouton, bloc));
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
          return { ok: true, texte: net(derniere.innerText) };
        },

        // La marque : ce que la page montre avant qu'on lui demande quelque
        // chose — ses échecs affichés, et combien de réponses de ChatGPT elle
        // porte. Avant le clic du micro, puis avant l'envoi.
        //
        // Une bannière déjà là n'est pas une réponse à notre demande — celle
        // d'un quota « bientôt atteint » reste affichée des jours. Et dans une
        // discussion, le fil porte déjà une réponse, finie et immobile, qui
        // passerait sinon pour celle qu'on attend.
        //
        // Rendue à Swift, qui la repasse à chaque `instantane`, et non gardée
        // ici : le pont renaît vierge à chaque document. Un « Recharger »
        // pendant l'attente l'effaçait, et la réponse d'avant, relue comme
        // nouvelle, était lue à haute voix à la place de celle qu'on
        // attendait.
        marquer() {
          return { echecs: [...alertesVisibles(), ...echecsEcrits()], reponses: tous(REPONSES).length };
        },

        // Ce que la page dit d'elle-même, en **un** aller-retour : chaque
        // tour d'une attente en coûtait deux ou trois, et relisait le texte
        // entier de la réponse quatre fois par seconde pendant que ChatGPT
        // l'écrivait — de quoi ralentir la génération même qu'on attendait.
        //
        // Toujours : la session, la conversation, les boutons. Sur demande
        // (`demande.texte`, `.reponse`, `.alertes`) : le texte de la zone, où
        // en est la réponse depuis la marque, et le premier échec apparu
        // depuis elle. `reperes` : les repères à suivre, vides pour le filet.
        // `marque` : ce que rendait `marquer` ; sans elle, ni la réponse ni
        // l'échec ne sont relevés — on ne sait pas ce qui est nouveau, et une
        // réponse d'avant prise pour la nouvelle serait rendue sans rien dire.
        //
        // Le point qui avait été manqué : pendant la dictée, ChatGPT retire la
        // zone de saisie du DOM et la remplace par la barre d'onde. Se fier à
        // sa seule présence faisait conclure « déconnecté » exactement pendant
        // qu'on dictait : le micro et l'arrêt comptent aussi (cf.
        // `RelaisVeille.session`).
        instantane(reperes, demande, marque) {
          const r = reperes || {}, d = demande || {};
          // Par le repère appris, et non par « une zone éditable
          // quelconque » : une conversation qui contient un document produit
          // par ChatGPT en offre une seconde, et la page se déclarait alors
          // « pas en train d'enregistrer » pendant qu'elle enregistrait.
          const zone = trouver('composeur', r.composeur);
          const arret = trouver('stop', r.stop);
          const composeur = !!zone && vu(zone);
          const etat = {
            ok: true,
            conversation: estConversation(location.pathname),
            authentification: estAuthentification(location) || inviteDeConnexion(),
            composeur, micro: !!trouver('micro', r.micro), stop: !!arret,
            // La zone absente *et* l'arrêt présent : la page écoute.
            enregistrement: !composeur && !!arret,
          };
          if (d.texte) etat.texte = zone ? texteDe(zone) : null;
          if (d.reponse && marque) {
            const reponses = tous(REPONSES);
            const nouvelles = Math.max(0, reponses.length - marque.reponses);
            const derniere = nouvelles ? reponses[reponses.length - 1] : null;
            const copier = derniere && boutonCopier(r.copierParent, r.copier, r.reponse).bouton;
            etat.reponse = {
              nouvelles,
              enCours: !etat.enregistrement && generationEnCours(zone, r.stop ? arret : null),
              // `textContent`, qui ne dispose rien : son calme suffit à
              // juger la fin, et la réponse n'est lue qu'une fois, finie.
              longueur: derniere ? derniere.textContent.length : 0,
              // Le bouton du tour, qui n'existe qu'une fois la réponse
              // finie — pas celui d'une réponse d'avant, qui la précède.
              copierPret: !!copier
                && !!(derniere.compareDocumentPosition(copier) & Node.DOCUMENT_POSITION_FOLLOWING),
            };
          }
          if (d.alertes && marque) etat.echec = echecNouveau(marque);
          return etat;
        },

        // Les règles qui ne regardent pas la page, pour que les tests les
        // atteignent sans elle.
        pur: { idEngendre, estConversation, estAuthentification, estEchec, estInvite, tri },

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

        // Le repère de `cible` que l'utilisateur désigne d'un clic — un
        // seul guetteur pour les deux parcours et pour tous les repères.
        //
        // Un clic hors sujet ne compte pas, et l'on continue d'écouter. À
        // l'étape du bouton d'envoi, on demande d'abord d'écrire quelque
        // chose : le premier clic tombe donc dans la zone de texte, et il
        // était retenu comme s'il désignait le bouton — la calibration
        // apprenait la zone de saisie à la place de la flèche bleue. Ignorer
        // plutôt que refuser : l'utilisateur cliquera le bon élément juste
        // après, ce qui est exactement ce qu'on attend.
        //
        // « Lire à haute voix » est parfois sous la réponse, parfois derrière
        // les trois points : le clic sur un ouvre-menu — la page le déclare,
        // `aria-haspopup` n'est pas deviné par nous — est retenu à part, et le
        // suivant est le bouton. Sans menu, le premier clic est le bon.
        //
        // « Copier » n'est retenu que s'il désigne ce que la dictée cliquera :
        // la paire du dernier bloc (cf. `paireCopier`), ou un repère que
        // `copierAutour` ramène à ce seul bouton, et toujours dans le tour de
        // la dernière réponse. La page en pose un sous chaque message, celui
        // de l'utilisateur compris : appris là, il copiait la demande. Un
        // repère vide dit ce refus à Swift, qui redemande. `selReponse` : le
        // repère de la réponse que la dictée consultera.
        guetter(cible, selReponse) {
          const genre = GENRE[cible];
          let menu = null;
          return ecouterLesClics((ev) => {
            const el = ev.target.closest(CLIQUABLE[genre] || '*');
            if (!convient(genre, el)) return null;
            if (cible === 'copier') return copierDesigne(el, derniereReponse(selReponse));
            const repere = { ok: true, selecteur: selecteurStable(el, genre, cible), parent: selecteurAncetre(el) };
            if (cible !== 'lecture') return repere;
            if (ouvreUnMenu(el) && !menu) { menu = repere; return null; } // on attend le vrai bouton
            return { ...repere, menu: menu ? menu.selecteur : '', menuParent: menu ? menu.parent : '' };
          });
        },

        // Les candidats de la calibration automatique pour un repère, à
        // éprouver dans l'ordre.
        //
        // Tirés du filet, dans son ordre : le `data-testid` d'abord, écrit
        // par la page pour ses propres tests et donc jamais traduit, puis les
        // libellés. Seuls restent les éléments visibles, du bon genre, qui
        // n'ouvrent pas de menu, et qui portent un repère où ils sont seuls
        // (cf. `seulA`). Aucun n'est cliqué ici : c'est Swift qui
        // éprouve, un par un, et s'arrête au premier dont l'effet se voit.
        candidats(cible) {
          const genre = GENRE[cible];
          const liste = [];
          for (const s of (HEURISTIQUES[cible] || [])) {
            for (const el of tous(s)) {
              if (!visible(el) || !convient(genre, el)) continue;
              if (genre === 'bouton' && ouvreUnMenu(el)) continue;
              const sel = premierRepere(el, seulA(el, document, genre));
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
            // Au premier niveau qui en contient, et seul à ce niveau (cf.
            // `copierAutour`) : plus haut, on entrerait dans les messages
            // voisins.
            const el = copierAutour(derniere, s);
            const c = el && !ouvreUnMenu(el) && repereCopier(el, derniere, [s]);
            if (c && !liste.some((x) => x.selecteur === c.selecteur && x.parent === c.parent)) liste.push(c);
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
