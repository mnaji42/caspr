import Foundation

extension RelaisPage {
    /// Le pont injecté dans la page.
    ///
    /// Il ne fait rien qu'un utilisateur ne ferait à la souris : cliquer deux
    /// boutons, lire la zone de texte, la vider. Il n'envoie aucun message, ne
    /// touche à aucune conversation, n'appelle aucun point d'entrée réseau.
    static let pont = #"""
    (() => {
      if (window.__relais) return;

      const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s;

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
          '[data-message-author-role="assistant"]',
          'article',
        ],
        copier: [
          '[data-testid="copy-turn-action-button"]',
          'button[aria-label*="copi" i]',
          'button[aria-label*="copy" i]',
        ],
      };

      const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0;

      function trouver(cible, selecteur) {
        if (selecteur) {
          try {
            const el = document.querySelector(selecteur);
            // Présence, et non visibilité, pour un sélecteur calibré.
            //
            // WebKit ne dispose pas la page tant que sa fenêtre n'a jamais été
            // affichée, et la nôtre naît hors champ : `getClientRects()` rend
            // alors une liste vide pour des éléments pourtant bien là. Le
            // bouton micro y survivait — il existe au chargement, donc il a été
            // disposé une fois — mais le bouton d'arrêt, créé au clic, restait
            // invisible au sens de cette fonction. D'où l'échec systématique à
            // la première dictée, et la réussite de toutes les suivantes :
            // cliquer soi-même le carré affiche la fenêtre, ce qui force la
            // mise en page pour de bon.
            //
            // Un sélecteur calibré désigne un élément que l'utilisateur a
            // cliqué lui-même : rien ne justifie de lui redemander ses
            // dimensions.
            if (el && el.isConnected) return el;
          } catch (e) { /* sélecteur devenu invalide : on tente les heuristiques */ }
        }
        for (const s of (HEURISTIQUES[cible] || [])) {
          for (const el of document.querySelectorAll(s)) {
            if (visible(el)) return el;
          }
        }
        return null;
      }

      // Un sélecteur qui a une chance de survivre au prochain déploiement.
      // Par ordre de solidité : identifiant, data-testid, aria-label. Le
      // chemin structurel n'est qu'un dernier recours — il casse au moindre
      // remaniement, mais recalibrer coûte trois clics.
      function selecteurStable(el) {
        if (el.id) return '#' + esc(el.id);
        const testid = el.getAttribute('data-testid');
        if (testid) return '[data-testid="' + testid.replace(/"/g, '\\"') + '"]';
        const aria = el.getAttribute('aria-label');
        if (aria) return '[aria-label="' + aria.replace(/"/g, '\\"') + '"]';

        const parts = [];
        let n = el;
        while (n && n.nodeType === 1 && parts.length < 6) {
          if (n.id) { parts.unshift('#' + esc(n.id)); break; }
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

      // Le premier ancêtre qui porte un identifiant stable.
      //
      // Capturé en même temps que l'élément lui-même, il permet de désigner
      // « ce bouton, dans ce bloc » plutôt que « un bouton qui ressemble à
      // celui-ci ». Pour le bouton « copier », la différence est décisive : la
      // page en contient un par message, et seule la paire dit lequel.
      function selecteurAncetre(el) {
        let n = el.parentElement;
        for (let i = 0; i < 5 && n; i++) {
          if (n.id) return '#' + esc(n.id);
          const testid = n.getAttribute('data-testid');
          if (testid) return '[data-testid="' + testid.replace(/"/g, '\\"') + '"]';
          const aria = n.getAttribute('aria-label');
          if (aria) return '[aria-label="' + aria.replace(/"/g, '\\"') + '"]';
          n = n.parentElement;
        }
        return '';
      }

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
        copierLaReponse(selParent, selCopier, selReponseRepli) {
          if (selParent && selCopier) {
            let parents = [];
            try { parents = [...document.querySelectorAll(selParent)]; } catch (e) {}
            const vus = parents.filter((p) => p.getClientRects().length > 0);
            const liste = vus.length ? vus : parents;
            if (liste.length) {
              // Le dernier : un fil neuf n'a qu'une réponse, mais un
              // rechargement qui n'aurait pas abouti en laisserait plusieurs.
              let bouton = null;
              try { bouton = liste[liste.length - 1].querySelector(selCopier); }
              catch (e) { bouton = null; }
              if (bouton) { bouton.click(); return { ok: true, voie: 'paire' }; }
            }
          }

          // Repli pour les configurations calibrées avant que la paire
          // n'existe : on part de la dernière réponse et on cherche autour.
          // La visibilité est exigée, elle : le bouton d'une réponse est
          // toujours affiché, celui d'un message d'utilisateur ne l'est qu'au
          // survol — c'est donc elle qui les distingue.
          let reponses = [];
          if (selReponseRepli) {
            try { reponses = [...document.querySelectorAll(selReponseRepli)]; } catch (e) {}
          }
          for (const s of HEURISTIQUES.reponse) {
            if (reponses.length) break;
            reponses = [...document.querySelectorAll(s)];
          }
          const visiblesR = reponses.filter((el) => el.getClientRects().length > 0);
          if (!visiblesR.length) return { ok: false, raison: 'pas de réponse' };

          let noeud = visiblesR[visiblesR.length - 1];
          for (let niveau = 0; niveau < 6 && noeud; niveau++) {
            for (const s of HEURISTIQUES.copier) {
              let trouves = [];
              try { trouves = [...noeud.querySelectorAll(s)]; } catch (e) { continue; }
              const vus = trouves.filter((b) => b.getClientRects().length > 0);
              if (!vus.length) continue;
              vus[vus.length - 1].click();
              return { ok: true, voie: 'repli', niveau };
            }
            noeud = noeud.parentElement;
          }
          return { ok: false, raison: 'pas de bouton copier' };
        },

        // Clique le **dernier** élément qui corresponde, et dit s'il existait.
        //
        // Le dernier, parce qu'une conversation en compte un par réponse. Le
        // fil est neuf à chaque passe, donc il n'y en a qu'un — mais s'en
        // remettre à cette certitude, c'est se préparer à lire la réponse
        // d'avant le jour où un rechargement n'aura pas abouti.
        cliquerDernier(cible, selecteur) {
          let elements = [];
          if (selecteur) {
            try { elements = [...document.querySelectorAll(selecteur)]; } catch (e) {}
          }
          if (!elements.length) {
            for (const s of (HEURISTIQUES[cible] || [])) {
              elements = [...document.querySelectorAll(s)];
              if (elements.length) break;
            }
          }
          const visibles = elements.filter((el) => el.isConnected);
          if (!visibles.length) return { ok: false, raison: 'introuvable' };
          visibles[visibles.length - 1].click();
          return { ok: true };
        },

        // La **dernière** réponse de la conversation.
        //
        // La dernière et non la première : un fil neuf n'en contient qu'une,
        // mais rien ne garantit qu'un rechargement ait abouti, et lire la
        // première rendrait alors la réponse d'avant sans que rien ne le
        // signale.
        lireReponse(selecteur) {
          let elements = [];
          if (selecteur) {
            try { elements = [...document.querySelectorAll(selecteur)]; } catch (e) {}
          }
          if (!elements.length) {
            for (const s of HEURISTIQUES.reponse) {
              elements = [...document.querySelectorAll(s)];
              if (elements.length) break;
            }
          }
          const visibles = elements.filter((el) => el.getClientRects().length > 0);
          if (!visibles.length) return { ok: false, raison: 'introuvable' };
          const t = visibles[visibles.length - 1].innerText || '';
          return { ok: true, texte: t.replace(/ /g, ' ').trim() };
        },

        // L'erreur que ChatGPT affiche lui-même.
        //
        // Sans la lire, un échec annoncé en toutes lettres dans la page se
        // traduisait par une attente muette de plusieurs minutes, la barre
        // bloquée sur « Transcription… », sans autre issue que de quitter
        // l'application.
        //
        // On vise `role="alert"`, qui est un rôle d'accessibilité normalisé et
        // non une classe générée, et on se rabat sur le texte pour les langues
        // où il ne serait pas posé.
        erreur() {
          const motifs = /n'a pas compris|pas compris|didn.t catch|try again|réessayer/i;
          // Le motif s'applique aussi aux `role="alert"`, et c'est le point.
          // Accepter n'importe quelle alerte visible faisait prendre pour un
          // échec de dictée la bannière « Limite d'utilisation hebdomadaire
          // bientôt atteinte », qui porte le même rôle et reste affichée des
          // jours durant : chaque dictée aurait été interrompue.
          for (const el of document.querySelectorAll('[role="alert"]')) {
            const t = (el.innerText || '').trim();
            if (t && motifs.test(t) && el.getClientRects().length > 0) {
              return { ok: true, message: t };
            }
          }
          for (const el of document.querySelectorAll('div, span, p')) {
            const t = (el.innerText || '').trim();
            if (t && t.length < 120 && motifs.test(t) && el.getClientRects().length > 0) {
              return { ok: true, message: t };
            }
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
        etat(selMicro, selStop) {
          const zone = document.querySelector(
            '#prompt-textarea, div[contenteditable="true"]'
          );
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
          const invite = /^(se connecter|connexion|log ?in|sign ?up|s'inscrire|inscription)/i;
          let deconnecte = false;
          for (const el of document.querySelectorAll('button, a')) {
            if (el.getClientRects().length === 0) continue;
            if (invite.test((el.innerText || '').trim())) { deconnecte = true; break; }
          }

          return {
            ok: true,
            url: location.href,
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
        calibrer() {
          return new Promise((resolve) => {
            const surClic = (ev) => {
              document.removeEventListener('click', surClic, true);
              const el = ev.target.closest(
                'button, [role="button"], [contenteditable="true"], textarea, input'
              ) || ev.target;
              resolve({ ok: true,
                        selecteur: selecteurStable(el),
                        parent: selecteurAncetre(el) });
            };
            document.addEventListener('click', surClic, true);
          });
        },
      };
    })();
    """#
}
