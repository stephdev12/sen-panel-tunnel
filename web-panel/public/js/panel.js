// SEN PANEL TUNNEL — Minimalist panel behaviors with Lucide icons

(function () {
  function initLucide() {
    if (typeof lucide !== 'undefined' && lucide.createIcons) {
      lucide.createIcons();
    }
  }

  function attachPasswordToggles() {
    document.querySelectorAll('input[type="password"]').forEach((input) => {
      if (input.dataset.toggleAttached) return;
      input.dataset.toggleAttached = '1';

      const wrapper = document.createElement('div');
      wrapper.className = 'password-field';
      input.parentNode.insertBefore(wrapper, input);
      wrapper.appendChild(input);

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'password-toggle';
      btn.setAttribute('aria-label', 'Afficher le mot de passe');
      btn.tabIndex = -1;
      btn.innerHTML = '<i data-lucide="eye" style="width:16px;height:16px;"></i>';
      wrapper.appendChild(btn);

      btn.addEventListener('click', () => {
        const willShow = input.type === 'password';
        input.type = willShow ? 'text' : 'password';
        btn.innerHTML = willShow
          ? '<i data-lucide="eye-off" style="width:16px;height:16px;"></i>'
          : '<i data-lucide="eye" style="width:16px;height:16px;"></i>';
        btn.setAttribute('aria-label', willShow ? 'Masquer le mot de passe' : 'Afficher le mot de passe');
        initLucide();
      });
    });
  }

  function attachActionMenus() {
    document.querySelectorAll('[data-menu-toggle]').forEach((btn) => {
      if (btn.dataset.menuAttached) return;
      btn.dataset.menuAttached = '1';
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const menu = btn.closest('.action-menu');
        const wasOpen = menu.classList.contains('open');
        document.querySelectorAll('.action-menu.open').forEach((m) => m.classList.remove('open'));
        if (!wasOpen) menu.classList.add('open');
      });
    });
    document.addEventListener('click', () => {
      document.querySelectorAll('.action-menu.open').forEach((m) => m.classList.remove('open'));
    });
  }

  function showCopyToast(message) {
    let toast = document.querySelector('.copy-toast');
    if (!toast) {
      toast = document.createElement('div');
      toast.className = 'copy-toast';
      document.body.appendChild(toast);
    }
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toast._hideTimer);
    toast._hideTimer = setTimeout(() => toast.classList.remove('show'), 1800);
  }

  function attachCopyButtons() {
    document.querySelectorAll('[data-copy-target]').forEach((btn) => {
      if (btn.dataset.copyAttached) return;
      btn.dataset.copyAttached = '1';
      btn.addEventListener('click', () => {
        const source = document.getElementById(btn.dataset.copyTarget);
        if (!source) return;
        const text = (source.value !== undefined ? source.value : source.textContent).trim();
        const done = () => {
          showCopyToast(btn.dataset.copiedLabel || 'Copié !');
          document.querySelectorAll('.action-menu.open').forEach((m) => m.classList.remove('open'));
        };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(done).catch(done);
        } else {
          const ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); } catch { /* best effort */ }
          document.body.removeChild(ta);
          done();
        }
      });
    });
  }

  function initAll() {
    initLucide();
    attachPasswordToggles();
    attachActionMenus();
    attachCopyButtons();
    initLucide();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initAll);
  } else {
    initAll();
  }
})();
