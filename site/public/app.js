import { releaseDetails } from './release.mjs';

const games = [...document.querySelectorAll('[data-game]')];
const popover = document.querySelector('#game-actions');
const playing = document.querySelector('.playing-state');
const status = document.querySelector('#demo-status');
let selected;

function closePreview(restoreFocus = true) {
  popover.hidden = true;
  playing.hidden = true;
  games.forEach(game => game.setAttribute('aria-expanded', 'false'));
  status.textContent = 'A little less between you and Play.';
  if (restoreFocus) selected?.focus();
}

games.forEach(game => game.addEventListener('click', () => {
  closePreview(false);
  selected = game;
  game.setAttribute('aria-expanded', 'true');
  document.querySelector('#selected-title').textContent = game.dataset.game;
  popover.hidden = false;
  document.querySelector('.play-button').focus();
}));
document.querySelector('.close-popover').addEventListener('click', () => closePreview());
document.querySelector('.back-button').addEventListener('click', () => closePreview());
document.querySelector('.play-button').addEventListener('click', () => {
  popover.hidden = true;
  playing.hidden = false;
  document.querySelector('#playing-title').textContent = selected.dataset.game;
  status.textContent = 'Preview only. No game was launched.';
  document.querySelector('.back-button').focus();
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && (!popover.hidden || !playing.hidden)) closePreview();
});
document.addEventListener('click', event => {
  if (!popover.hidden && !event.target.closest('.app-window')) closePreview(false);
});
document.querySelector('.demo-link').addEventListener('click', () => games[0].focus({ preventScroll: true }));

async function refreshRelease() {
  try {
    const response = await fetch('/downloads/manifest.json', { cache: 'no-store', signal: AbortSignal.timeout(5000) });
    if (!response.ok) return;
    const release = releaseDetails(await response.json());
    if (!release) return;
    document.querySelectorAll('[data-release-link]').forEach(link => {
      link.href = release.href;
      link.setAttribute('download', '');
      link.querySelector('[data-release-label]').textContent = 'Download for Mac';
    });
    document.querySelectorAll('[data-release-detail]').forEach(node => { node.textContent = release.detail; });
    document.querySelector('[data-release-status]').textContent = 'Signed, notarized, and ready for your Mac.';
    document.querySelector('[data-release-faq]').textContent = 'Pufflet is available now. Use Download for Mac on this page to get the latest signed and notarized release. Updates are delivered through the app.';
  } catch {
    // The project links remain usable while the first release is unavailable.
  }
}
refreshRelease();
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refreshRelease();
});
