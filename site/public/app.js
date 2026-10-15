import { releaseDetails } from './release.mjs';

const capture = document.querySelector('#native-capture');
const covers = [...document.querySelectorAll('.native-cover')];
const playPreview = document.querySelector('.native-play-hit');
const back = document.querySelector('.native-back');
const hint = document.querySelector('.demo-hint');
const pointer = document.querySelector('.cover-pointer');
const previewStatus = document.querySelector('#native-preview-status');
let selected;

function closePreview(restoreFocus = true) {
  capture.src = '/images/native-library.jpg';
  capture.alt = 'Pufflet’s native macOS library with three installed game covers.';
  covers.forEach(cover => cover.setAttribute('aria-expanded', 'false'));
  playPreview.hidden = back.hidden = true;
  hint.hidden = pointer.hidden = false;
  if (restoreFocus) selected?.focus();
}

covers.forEach(cover => cover.addEventListener('click', () => {
  selected = cover;
  capture.src = cover.dataset.capture;
  capture.alt = `Pufflet’s native ${cover.dataset.game} Play popover, with Installed, Play, and Show files.`;
  covers.forEach(item => item.setAttribute('aria-expanded', String(item === cover)));
  playPreview.style.left = cover.dataset.playLeft;
  playPreview.hidden = back.hidden = false;
  hint.hidden = pointer.hidden = true;
  playPreview.focus();
  previewStatus.textContent = `${cover.dataset.game} preview selected.`;
}));
back.addEventListener('click', () => closePreview());
playPreview.addEventListener('click', () => {
  closePreview();
  previewStatus.textContent = 'Preview complete. No game was launched.';
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !back.hidden) closePreview();
});
document.addEventListener('click', event => {
  if (!back.hidden && !event.target.closest('#library-demo')) closePreview(false);
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
