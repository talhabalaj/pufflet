import { releaseDetails } from './release.mjs';

const scene = document.querySelector('#library-demo');
const covers = [...document.querySelectorAll('.native-cover')];
const panel = document.querySelector('.native-popover');
const panelImage = document.querySelector('.native-popover-capture');
const playPreview = document.querySelector('.native-play-hit');
const back = document.querySelector('.native-back');
const hint = document.querySelector('.demo-hint');
const previewStatus = document.querySelector('#native-preview-status');
let selected;
let pendingCover;
let previewRequest = 0;

// Keyboard navigation stays instant; pointer interactions use the short transitions.
document.addEventListener('keydown', () => document.documentElement.setAttribute('data-keyboard', ''), true);
document.addEventListener('pointerdown', () => document.documentElement.removeAttribute('data-keyboard'), true);

async function prepareCapture(cover) {
  const image = cover.querySelector('img');
  if (!image.hasAttribute('src')) image.src = cover.dataset.capture;
  await image.decode();
}

function closePreview(restoreFocus = true) {
  const trigger = pendingCover ?? selected;
  pendingCover = undefined;
  previewRequest++;
  panel.removeAttribute('data-open');
  scene.classList.remove('popover-on-right');
  panel.inert = true;
  covers.forEach(cover => cover.setAttribute('aria-expanded', 'false'));
  back.hidden = true;
  hint.hidden = false;
  if (restoreFocus) trigger?.focus({ preventScroll: true });
}

covers.forEach(cover => {
  cover.addEventListener('pointerenter', () => { prepareCapture(cover).catch(() => {}); }, { once: true });
  cover.addEventListener('click', async () => {
    if (selected === cover && panel.hasAttribute('data-open')) return closePreview();
    const request = ++previewRequest;
    pendingCover = cover;
    try {
      await prepareCapture(cover);
      if (request !== previewRequest) return;
      pendingCover = undefined;
      selected = cover;
      scene.classList.toggle('popover-on-right', cover.classList.contains('stardew-cover'));
      panelImage.src = cover.dataset.capture;
      panelImage.style.left = cover.dataset.popupCrop;
      panel.style.left = cover.dataset.popupLeft;
      panel.style.transformOrigin = `${cover.dataset.origin} 0%`;
      covers.forEach(item => item.setAttribute('aria-expanded', String(item === cover)));
      panel.setAttribute('aria-label', `${cover.dataset.game} native Play preview`);
      panel.inert = false;
      panel.setAttribute('data-open', '');
      back.hidden = false;
      hint.hidden = true;
      playPreview.focus({ preventScroll: true });
      previewStatus.textContent = `${cover.dataset.game} preview selected.`;
    } catch {
      if (request === previewRequest) {
        pendingCover = undefined;
        previewStatus.textContent = 'The preview could not load. Select the cover to try again.';
      }
    }
  });
});
back.addEventListener('click', () => closePreview());
playPreview.addEventListener('click', () => {
  closePreview();
  previewStatus.textContent = 'Preview complete. No game was launched.';
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && (!back.hidden || pendingCover)) closePreview();
});
document.addEventListener('click', event => {
  if ((!back.hidden || pendingCover) && !event.target.closest('#library-demo')) closePreview(false);
});
document.querySelector('.demo-link').addEventListener('click', () => covers[1].focus({ preventScroll: true }));

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
