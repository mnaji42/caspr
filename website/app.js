/* =============================================================================
   Caspr — le site
   -----------------------------------------------------------------------------
   Trois comportements, et rien de plus : le repli des questions, la fenêtre du
   guide d'installation, et la ligne de version tirée de GitHub. Tout le contenu
   est déjà dans le HTML — ce fichier n'écrit aucun texte que le lecteur aurait
   besoin de voir si le script ne s'exécutait pas.
   ============================================================================= */

(() => {
  'use strict';

  const LANG = document.documentElement.lang === 'en' ? 'en' : 'fr';
  const t = (fr, en) => (LANG === 'en' ? en : fr);

  /* ==========================================================================
     Le texte qui s'écrit, dans le titre
     -------------------------------------------------------------------------
     Il énonce ce que Caspr écrit, pas des slogans. La doublure invisible du
     HTML réserve la place de la plus longue phrase, donc rien ne bouge autour.
     ========================================================================== */

  /* Des compléments courts, et de longueur voisine : la doublure réserve la
     place du plus long, et un écart trop grand creuserait un vide sous le
     titre. Ils disent ce que Caspr écrit — pas des slogans. */
  const PHRASES = LANG === 'en'
    ? ['at the speed of your thoughts', 'right where your caret is',
       'into your daily notes', 'offline, or through ChatGPT']
    : ['à la vitesse de votre pensée', 'là où est votre curseur',
       'dans vos notes du jour', 'hors ligne ou par ChatGPT'];

  const typed = document.getElementById('typed');
  const ghost = document.querySelector('.typing-ghost');
  const calmer = window.matchMedia('(prefers-reduced-motion: reduce)');

  if (typed) {
    /* La doublure prend la plus longue des phrases, quelle que soit la langue :
       la réserve de place ne dépend pas de l'ordre du tableau. */
    if (ghost) {
      ghost.textContent = PHRASES.reduce((a, b) => (b.length > a.length ? b : a));
    }

    if (calmer.matches) {
      /* Mouvement réduit : la phrase est posée, pas tapée. Le titre reste
         complet — c'est l'animation qu'on retire, pas l'information. */
      typed.textContent = PHRASES[0];
    } else {
      let phrase = 0;
      let count = 0;
      let erasing = false;
      let timer = null;

      const step = () => {
        const current = PHRASES[phrase];
        count += erasing ? -1 : 1;
        typed.textContent = current.slice(0, count);

        let wait = erasing ? 28 : 45;
        if (!erasing && count === current.length) {
          erasing = true;
          wait = 2400;
        } else if (erasing && count === 0) {
          erasing = false;
          phrase = (phrase + 1) % PHRASES.length;
          wait = 420;
        }
        timer = setTimeout(step, wait);
      };

      step();

      /* Une boucle décorative n'a rien à faire tourner dans un onglet masqué. */
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) {
          clearTimeout(timer);
        } else {
          clearTimeout(timer);
          timer = setTimeout(step, 400);
        }
      });
    }
  }

  /* ==========================================================================
     Les questions
     ========================================================================== */

  document.querySelectorAll('.faq-q').forEach((button) => {
    button.addEventListener('click', () => {
      const item = button.closest('.faq-item');
      const open = button.getAttribute('aria-expanded') === 'true';
      button.setAttribute('aria-expanded', String(!open));
      item.dataset.open = String(!open);
    });
  });

  /* ==========================================================================
     Le guide d'installation
     -------------------------------------------------------------------------
     Une vraie fenêtre modale : le focus y entre, y reste tant qu'elle est
     ouverte, et retourne au bouton qui l'a ouverte à la fermeture.
     ========================================================================== */

  const STEPS = [
    {
      image: '01-fichier-telecharger-doubleclick.png',
      title: t('Ouvrez le fichier téléchargé', 'Open the downloaded file'),
      text: t(
        'Double-cliquez sur <code>Caspr.dmg</code> dans vos téléchargements pour monter l\'image disque.',
        'Double-click <code>Caspr.dmg</code> in your downloads to mount the disk image.'
      )
    },
    {
      image: '02-dmg-ouvert-doubleclick.png',
      title: t('Double-cliquez sur Caspr', 'Double-click Caspr'),
      text: t(
        'La fenêtre du disque s\'ouvre avec une seule icône. Double-cliquez sur Caspr.',
        'The disk window opens with a single icon. Double-click Caspr.'
      )
    },
    {
      image: '03-erreur-car-car-pas-verifier-par-apple-terminer.png',
      title: t('macOS refuse — c\'est attendu', 'macOS refuses — this is expected'),
      text: t(
        'Au premier lancement, macOS annonce qu\'il n\'a pas pu vérifier l\'application. Cliquez sur <strong>Terminer</strong> : l\'autorisation se donne au réglage suivant.',
        'On first launch, macOS reports it could not verify the app. Click <strong>Done</strong> — you grant permission in the next step.'
      )
    },
    {
      image: '04-pomme-puis-reglage-system.png',
      title: t('Ouvrez les Réglages Système', 'Open System Settings'),
      text: t(
        'Menu Pomme, en haut à gauche de l\'écran, puis <strong>Réglages Système</strong>.',
        'Apple menu, top left of the screen, then <strong>System Settings</strong>.'
      )
    },
    {
      image: '05-cliquer-sur-confidentialite-et-securite.png',
      title: t('Allez dans Confidentialité et sécurité', 'Go to Privacy & Security'),
      text: t(
        'Dans la colonne de gauche, choisissez <strong>Confidentialité et sécurité</strong>.',
        'In the left column, choose <strong>Privacy &amp; Security</strong>.'
      )
    },
    {
      image: '06-scroller-tout-en-bas-cliquer-ouvrir-quand-meme.png',
      title: t('Cliquez sur « Ouvrir quand même »', 'Click "Open Anyway"'),
      text: t(
        'Descendez tout en bas de la page. Caspr y est mentionné, avec un bouton <strong>Ouvrir quand même</strong>.',
        'Scroll to the bottom of the page. Caspr is listed there, with an <strong>Open Anyway</strong> button.'
      )
    },
    {
      image: '07-Popup-souvre-installer-dans-application.png',
      title: t('Installez Caspr', 'Install Caspr'),
      text: t(
        'Caspr propose de s\'installer dans Applications. Cliquez sur <strong>Installer et ouvrir</strong> : il s\'y copie, éjecte l\'image et rouvre la bonne copie.',
        'Caspr offers to install itself in Applications. Click <strong>Installer et ouvrir</strong>: it copies itself there, ejects the disk image and reopens the right copy.'
      )
    },
    {
      image: '08-attendre-quelque-seconde-onboarding-souvre.png',
      title: t('Caspr s\'ouvre', 'Caspr opens'),
      text: t(
        'Après quelques secondes, l\'accueil s\'affiche : il vous fait choisir votre voie, macOS ou ChatGPT, puis vous guide pour les deux autorisations nécessaires, le micro et l\'accessibilité.',
        'After a few seconds the welcome screen appears: it has you choose your path, macOS or ChatGPT, then walks you through the two permissions needed, microphone and accessibility.'
      )
    }
  ];

  /* L'URL stable que produit scripts/package-dmg.sh. Elle sert de repli : le
     lien réellement publié est relu plus bas dans la réponse de GitHub, qui
     seule sait quelle image est attachée à la dernière version. */
  const DMG_FALLBACK = 'https://github.com/mnaji42/caspr/releases/latest/download/Caspr.dmg';
  let dmgUrl = DMG_FALLBACK;

  const modal = document.getElementById('modal');
  const dialog = modal && modal.querySelector('.modal');
  const stepCount = document.getElementById('step-count');
  const stepTitle = document.getElementById('step-title');
  const stepText = document.getElementById('step-text');
  const stepImage = document.getElementById('step-image');
  const stepLive = document.getElementById('step-live');
  const stepDots = document.getElementById('step-dots');
  const prevBtn = document.getElementById('step-prev');
  const nextBtn = document.getElementById('step-next');

  let current = 0;
  let lastFocused = null;

  const pad = (n) => String(n).padStart(2, '0');

  function render(index) {
    current = Math.max(0, Math.min(index, STEPS.length - 1));
    const step = STEPS[current];

    stepCount.textContent = `${pad(current + 1)} / ${pad(STEPS.length)}`;
    stepTitle.textContent = step.title;
    stepText.innerHTML = step.text;
    stepImage.src = `images/${step.image}`;
    /* L'image illustre le texte qui la précède : la décrire une seconde fois
       ferait doublon au lecteur d'écran. */
    stepImage.alt = '';

    prevBtn.disabled = current === 0;
    nextBtn.disabled = current === STEPS.length - 1;

    Array.from(stepDots.children).forEach((dot, i) => {
      dot.setAttribute('aria-current', String(i === current));
    });

    stepLive.textContent = t(
      `Étape ${current + 1} sur ${STEPS.length} : ${step.title}`,
      `Step ${current + 1} of ${STEPS.length}: ${step.title}`
    );
  }

  if (modal) {
    STEPS.forEach((_, i) => {
      const dot = document.createElement('button');
      dot.type = 'button';
      dot.setAttribute('aria-label', t(`Étape ${i + 1}`, `Step ${i + 1}`));
      dot.addEventListener('click', () => render(i));
      stepDots.appendChild(dot);
    });

    prevBtn.addEventListener('click', () => render(current - 1));
    nextBtn.addEventListener('click', () => render(current + 1));

    /* Les flèches parcourent les étapes quand le focus est sur les points. */
    stepDots.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowRight') { render(current + 1); stepDots.children[current].focus(); }
      if (event.key === 'ArrowLeft') { render(current - 1); stepDots.children[current].focus(); }
    });

    const FOCUSABLE =
      'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])';

    function trapFocus(event) {
      if (event.key === 'Escape') { closeModal(); return; }
      if (event.key !== 'Tab') return;

      const items = Array.from(dialog.querySelectorAll(FOCUSABLE))
        .filter((el) => el.offsetParent !== null);
      if (!items.length) return;

      const first = items[0];
      const last = items[items.length - 1];

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    function openModal() {
      lastFocused = document.activeElement;
      render(0);
      modal.dataset.open = 'true';
      document.body.dataset.modalOpen = 'true';
      dialog.focus();
      document.addEventListener('keydown', trapFocus);
    }

    function closeModal() {
      modal.dataset.open = 'false';
      delete document.body.dataset.modalOpen;
      document.removeEventListener('keydown', trapFocus);
      if (lastFocused) lastFocused.focus();
    }

    document.getElementById('modal-close').addEventListener('click', closeModal);
    document.getElementById('modal-done').addEventListener('click', closeModal);

    /* Un clic sur le fond ferme, un clic dans la fenêtre non. */
    modal.addEventListener('click', (event) => {
      if (event.target === modal) closeModal();
    });

    document.querySelectorAll('.js-download').forEach((button) => {
      button.addEventListener('click', () => {
        window.location.href = dmgUrl;
        openModal();
      });
    });
  }

  /* ==========================================================================
     La version publiée
     -------------------------------------------------------------------------
     La ligne porte déjà un texte utile dans le HTML. Si GitHub ne répond pas,
     ce texte reste : rien ne clignote, rien ne se vide.
     ========================================================================== */

  const releaseText = document.getElementById('release-text');

  if (releaseText) {
    fetch('https://api.github.com/repos/mnaji42/caspr/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' }
    })
      .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
      .then((release) => {
        if (!release || !release.tag_name) return;

        const dmg = (release.assets || []).find((asset) => asset.name.endsWith('.dmg'));
        if (dmg && dmg.browser_download_url) {
          dmgUrl = dmg.browser_download_url;
          const retry = document.querySelector('.modal-foot a');
          if (retry) retry.href = dmgUrl;
        }

        const date = release.published_at
          ? new Date(release.published_at).toLocaleDateString(LANG === 'en' ? 'en-GB' : 'fr-FR', {
              day: 'numeric', month: 'long', year: 'numeric'
            })
          : null;

        const parts = [
          t(`Version ${release.tag_name}`, `Version ${release.tag_name}`),
          date ? t(`publiée le ${date}`, `released ${date}`) : null,
          t('gratuite et sous licence MIT', 'free, MIT licensed')
        ].filter(Boolean);

        releaseText.textContent = `${parts.join(' · ')}.`;
      })
      .catch(() => { /* La ligne garde son texte d'origine. */ });
  }
})();
