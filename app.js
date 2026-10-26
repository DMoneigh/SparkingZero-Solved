"use strict";

const STORAGE_KEY = "sparking-control-room-v1";
const defaults = { health: true, ki: true, sparking: false, fps: true, skill: false, frameRate: 60 };
const builtInProfiles = [
  { id: "training", name: "Training preset", description: "Room to practice. Full health and Ki, with a steady 60 FPS preview.", settings: { ...defaults } },
  { id: "full-power", name: "Full power", description: "No holding back. Every power enabled, with a 120 FPS preview cap.", settings: { health: true, ki: true, sparking: true, fps: true, skill: true, frameRate: 120 } },
  { id: "clean-slate", name: "Clean slate", description: "Back to basics. All modifications off, ready for your next experiment.", settings: { health: false, ki: false, sparking: false, fps: false, skill: false, frameRate: 60 } }
];
const featureNames = { health: "Max Health", ki: "Max Ki", sparking: "Unlimited Sparking Mode", fps: "Control Frame Rate", skill: "Max Skill Count Bars" };
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
let state = { settings: { ...defaults }, profile: "Training preset", customProfiles: [], reducedMotion: false, events: [] };
let storageAvailable = true;
let loadWarning = "";
let menuVisible = true;
let toastTimer;
let preview = { health: 100, ki: 100, skill: 3 };
let lastFrame = 0;
let hitUntil = 0;

function validSettings(settings) {
  return settings && Object.keys(featureNames).every((key) => typeof settings[key] === "boolean")
    && Number.isInteger(settings.frameRate) && (settings.frameRate === 0 || (settings.frameRate >= 30 && settings.frameRate <= 240));
}

function loadState() {
  let raw;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch (error) {
    storageAvailable = false;
    loadWarning = "Browser storage is unavailable. Changes will last for this session only.";
    console.warn(loadWarning, error);
    return;
  }
  if (!raw) return;
  let saved;
  try {
    saved = JSON.parse(raw);
  } catch (error) {
    loadWarning = "Saved workspace data could not be read. Default controls were restored.";
    console.warn(loadWarning, error);
    return;
  }
  if (!saved || !validSettings(saved.settings) || typeof saved.profile !== "string" || typeof saved.reducedMotion !== "boolean"
    || !Array.isArray(saved.customProfiles) || !Array.isArray(saved.events)
    || !saved.customProfiles.every((profile) => profile && typeof profile.id === "string" && typeof profile.name === "string" && typeof profile.description === "string" && validSettings(profile.settings))
    || !saved.events.every((event) => event && typeof event.message === "string" && Number.isFinite(event.time))) {
    loadWarning = "Saved workspace data was invalid. Default controls were restored.";
    console.warn(loadWarning);
    return;
  }
  state = { settings: { ...saved.settings }, profile: saved.profile, reducedMotion: saved.reducedMotion, customProfiles: saved.customProfiles, events: saved.events.slice(0, 100) };
}

function saveState() {
  if (storageAvailable) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch (error) {
      storageAvailable = false;
      console.warn("Unable to save the workspace.", error);
      notify("Storage unavailable. Changes are only saved for this session.");
    }
  }
  $("#save-status").innerHTML = storageAvailable ? '<svg><use href="#i-check"/></svg>Changes saved locally' : '<svg><use href="#i-info"/></svg>Session only - storage unavailable';
}

function notify(message) {
  clearTimeout(toastTimer);
  $("#toast span").textContent = message;
  $("#toast").hidden = false;
  toastTimer = setTimeout(() => { $("#toast").hidden = true; }, 3500);
}

function log(message) {
  state.events.unshift({ message, time: Date.now() });
  state.events = state.events.slice(0, 100);
  renderLog();
  saveState();
}

function renderLog() {
  const container = $("#log-list");
  container.replaceChildren();
  if (!state.events.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "A fresh start. Your next control change will appear here.";
    container.append(empty);
  }
  for (const event of state.events) {
    const row = document.createElement("div");
    row.className = "log-row";
    row.innerHTML = '<svg><use href="#i-bolt"/></svg><span></span><time></time>';
    row.querySelector("span").textContent = event.message;
    const date = new Date(event.time);
    row.querySelector("time").dateTime = date.toISOString();
    row.querySelector("time").textContent = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    row.querySelector("time").title = date.toLocaleString();
    container.append(row);
  }
}

function renderPreview() {
  if (state.settings.health) preview.health = 100;
  if (state.settings.ki) preview.ki = 100;
  if (state.settings.skill) preview.skill = 6;
  $("#health-value").innerHTML = `${preview.health}<span>%</span>`;
  $("#ki-value").innerHTML = `${preview.ki}<span>%</span>`;
  $("#skill-value").innerHTML = `${preview.skill} <span>/ 6</span>`;
  $$("#health-bar i").forEach((bar, index) => bar.classList.toggle("depleted", index >= Math.ceil(preview.health / 10)));
  $$("#ki-bar i").forEach((bar, index) => bar.classList.toggle("depleted", index >= Math.ceil(preview.ki / 10)));
  $$("#skill-bars i").forEach((bar, index) => bar.classList.toggle("depleted", index >= preview.skill));
  $("#hud-health").textContent = `${preview.health}%`;
  $("#hud-health-bar").style.width = `${preview.health}%`;
  $("#hud-energy").innerHTML = `KI ${preview.ki}% <b>/</b> SKILL ${preview.skill}`;
  $("#test-attack").innerHTML = preview.health === 0 ? 'Reset dummy <span>&#8599;</span>' : 'Test attack <span>&#8599;</span>';
  $(".hero").classList.toggle("powered", state.settings.sparking);
}

function render() {
  const settings = state.settings;
  $$("[data-toggle]").forEach((button) => button.setAttribute("aria-checked", String(settings[button.dataset.toggle])));
  $$("[data-status]").forEach((status) => {
    const enabled = settings[status.dataset.status];
    status.textContent = enabled ? "Enabled" : "Disabled";
    status.classList.toggle("disabled", !enabled);
  });
  const count = Object.keys(featureNames).filter((key) => settings[key]).length;
  $("#active-count").innerHTML = `${String(count).padStart(2, "0")} <small>ACTIVE</small>`;
  $("#fps-stat").innerHTML = settings.fps && settings.frameRate ? `${settings.frameRate} <small>FPS</small>` : '&#8734; <small>UNCAPPED</small>';
  $("#frame-value").textContent = settings.frameRate || "\u221e";
  $("#fps-range").value = settings.frameRate || 240;
  $("#fps-range").style.setProperty("--progress", `${((Number($("#fps-range").value) - 30) / 210) * 100}%`);
  $("#fps-range").disabled = !settings.fps;
  $$("[data-fps]").forEach((button) => {
    const selected = Number(button.dataset.fps) === settings.frameRate;
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", String(selected));
    button.disabled = !settings.fps;
  });
  $(".sparking-card").classList.toggle("is-active", settings.sparking);
  $("#sparking-value").textContent = settings.sparking ? "Always sparking" : "No time limit";
  $("#sparking-description").textContent = settings.sparking ? "Unlimited power in the preview" : "Activate to keep the spark alive";
  $("#current-profile").textContent = state.profile;
  $("#profile-stat").textContent = state.profile === "Training preset" ? "Training" : state.profile.length > 12 ? "Custom" : state.profile;
  $("#profile-stat").title = state.profile;
  $("#profile-count").textContent = builtInProfiles.length + state.customProfiles.length;
  $("#motion-toggle").setAttribute("aria-checked", String(state.reducedMotion));
  document.body.classList.toggle("reduced-motion", state.reducedMotion);
  renderPreview();
}

function changeSettings(message) {
  state.profile = "Custom";
  render();
  log(message);
}

function renderProfiles() {
  const container = $("#profiles-list");
  container.replaceChildren();
  for (const profile of [...builtInProfiles, ...state.customProfiles]) {
    const card = document.createElement("article");
    card.className = "profile-card";
    card.innerHTML = '<span class="feature-icon amber"><svg><use href="#i-sliders"/></svg></span><h2></h2><p></p><div class="profile-meta"></div><button class="button">Apply profile <svg><use href="#i-arrow"/></svg></button>';
    card.querySelector("h2").textContent = profile.name;
    card.querySelector("p").textContent = profile.description;
    const count = Object.keys(featureNames).filter((key) => profile.settings[key]).length;
    card.querySelector(".profile-meta").textContent = `${count} active mods / ${profile.settings.fps && profile.settings.frameRate ? profile.settings.frameRate + " FPS" : "Uncapped"} / Local preview`;
    const apply = card.querySelector("button");
    apply.classList.toggle("primary", state.profile === profile.name);
    apply.addEventListener("click", () => {
      state.settings = { ...profile.settings };
      state.profile = profile.name;
      preview = { health: 100, ki: 100, skill: 3 };
      render();
      renderProfiles();
      log(`Applied "${profile.name}" profile.`);
      notify(`${profile.name} applied to the preview.`);
    });
    if (!builtInProfiles.includes(profile)) {
      const remove = document.createElement("button");
      remove.className = "text-button delete-profile";
      remove.textContent = "Delete profile";
      remove.addEventListener("click", () => {
        state.customProfiles = state.customProfiles.filter((item) => item.id !== profile.id);
        if (state.profile === profile.name) state.profile = "Custom";
        render();
        renderProfiles();
        log(`Deleted "${profile.name}" profile.`);
        notify("Profile deleted. Current controls are unchanged.");
      });
      card.append(remove);
    }
    container.append(card);
  }
}

function showPage(name) {
  if (!["control-room", "profiles", "session-log", "settings"].includes(name)) name = "control-room";
  $$(".page").forEach((page) => { page.hidden = page.id !== `page-${name}`; });
  $$(".nav-item").forEach((button) => {
    button.classList.toggle("selected", button.dataset.page === name);
    if (button.dataset.page === name) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  $("#breadcrumb-page").textContent = name.replaceAll("-", " ").toUpperCase();
  if (name === "profiles") renderProfiles();
  if (name === "session-log") renderLog();
  window.scrollTo({ top: 0, behavior: "instant" });
}

function toggleMenu() {
  menuVisible = !menuVisible;
  if ($("#info-dialog").open) $("#info-dialog").close();
  $("#app-shell").hidden = !menuVisible;
  $("#hidden-screen").hidden = menuVisible;
  (menuVisible ? $("#hide-menu") : $("#restore-menu")).focus();
}

function showDialog(content) {
  $("#dialog-content").innerHTML = content;
  $("#info-dialog").showModal();
}

loadState();
render();
renderProfiles();
renderLog();
showPage(location.hash.slice(1));
if (!state.events.length) log("Local training preview started. No game process is attached.");
else saveState();
if (loadWarning) notify(loadWarning);

$$("[data-toggle]").forEach((button) => button.addEventListener("click", () => {
  const key = button.dataset.toggle;
  state.settings[key] = !state.settings[key];
  changeSettings(`${featureNames[key]} ${state.settings[key] ? "enabled" : "disabled"} in preview.`);
}));

$("#fps-range").addEventListener("input", (event) => {
  state.settings.frameRate = Number(event.target.value);
  state.profile = "Custom";
  render();
});
$("#fps-range").addEventListener("change", () => log(`Preview frame cap set to ${state.settings.frameRate} FPS.`));
$$("[data-fps]").forEach((button) => button.addEventListener("click", () => {
  state.settings.frameRate = Number(button.dataset.fps);
  changeSettings(state.settings.frameRate ? `Preview frame cap set to ${state.settings.frameRate} FPS.` : "Preview frame cap removed.");
}));

$("#enable-all").addEventListener("click", () => {
  for (const key of Object.keys(featureNames)) state.settings[key] = true;
  changeSettings("All five controls enabled in preview.");
  notify("All controls enabled. Go beyond your limits.");
});
$("#reset-all").addEventListener("click", () => {
  state.settings = { ...defaults };
  state.profile = "Training preset";
  preview = { health: 100, ki: 100, skill: 3 };
  render();
  log("Controls restored to the training preset.");
  notify("Training defaults restored.");
});
$("#test-attack").addEventListener("click", () => {
  if (preview.health === 0) {
    preview = { health: 100, ki: 100, skill: 3 };
    log("Training dummy reset.");
    notify("Training dummy restored.");
  } else {
    if (!state.settings.health) preview.health = Math.max(0, preview.health - 20);
    if (!state.settings.ki) preview.ki = Math.max(0, preview.ki - 25);
    if (!state.settings.skill) preview.skill = Math.max(0, preview.skill - 1);
    hitUntil = performance.now() + 500;
    log(`Training attack: health ${state.settings.health ? "protected" : preview.health + "%"}, Ki ${state.settings.ki ? "protected" : preview.ki + "%"}.`);
    notify(state.settings.health ? "Attack absorbed. Max Health is protecting your dummy." : `Attack landed. Training health: ${preview.health}%.`);
  }
  renderPreview();
});
$$("[data-page], [data-go]").forEach((button) => button.addEventListener("click", () => {
  const name = button.dataset.page || button.dataset.go;
  location.hash = name;
  showPage(name);
}));
window.addEventListener("hashchange", () => showPage(location.hash.slice(1)));
$("#hide-menu").addEventListener("click", toggleMenu);
$("#restore-menu").addEventListener("click", toggleMenu);
$("#hotkeys-button").addEventListener("click", () => showDialog('<h2>A shortcut to your power.</h2><div class="shortcut-row"><span>Show / hide the control room</span><kbd>F6</kbd></div><div class="shortcut-row"><span>Open keyboard shortcuts</span><kbd>?</kbd></div><div class="shortcut-row"><span>Close a dialog</span><kbd>Esc</kbd></div><p>Click inside the preview first to give it keyboard focus. These shortcuts work on this page, not inside the Windows game. You can also use the F6 button in the header.</p>'));
$("#about-button").addEventListener("click", () => showDialog('<h2>Power, with transparency.</h2><p>Created by Dez\'s Minion. This is an interactive, local mod-menu prototype for DRAGON BALL: Sparking! ZERO, with original preview artwork.</p><p>The supplied archive was inspected: it contains a compiled Windows Unreal Engine game, including a shipping executable and packaged .pak / .ucas / .utoc assets, not editable source.</p><p>This browser interface does not inject code, patch files, or change game memory. All five controls here affect the training simulation only. The separate Windows integration in the native folder uses UE4SS and a native F6 panel; it has not been exercised against your running game.</p><p>Your browser settings and profiles stay in this browser and are not sent to the native mod. This project is not affiliated with the game publisher.</p>'));
$("#native-setup").addEventListener("click", () => showDialog('<h2>The native control room.</h2><p>The browser preview and Windows mod are separate. For gameplay controls, close the game and follow <strong>native\\INSTRUCTIONS.txt</strong>.</p><p>In PowerShell, run <code>.\\native\\Install-Mod.ps1 -GameDirectory \'D:\\Games\\DRAGON BALL Sparking! ZERO\' -DownloadLoader</code>, replacing the path with your installed game folder.</p><p>Launch the game normally, open <strong>Launch-ModMenu.cmd</strong>, enter an offline battle, and enable controls. F6 shows or hides the native panel. Use borderless/windowed mode.</p><p>The installer fetches a hash-pinned UE4SS bundle and refuses existing loader conflicts. Live compatibility with your executable remains unverified. No online, DRM or anti-cheat bypass is included.</p>'));
$("#close-dialog").addEventListener("click", () => $("#info-dialog").close());
$("#info-dialog").addEventListener("click", (event) => {
  if (event.target === $("#info-dialog")) {
    const bounds = $("#info-dialog").getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) $("#info-dialog").close();
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key === "F6" && !event.repeat) {
    event.preventDefault();
    toggleMenu();
  }
  const typing = event.target instanceof HTMLElement && (event.target.matches("input, textarea, select") || event.target.isContentEditable);
  if (event.key === "?" && !typing && !$("#info-dialog").open && menuVisible) {
    event.preventDefault();
    $("#hotkeys-button").click();
  }
});
$("#save-profile-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const input = $("#profile-name");
  const name = input.value.trim();
  if (!name) { input.setCustomValidity("Enter a profile name."); input.reportValidity(); return; }
  if ([...builtInProfiles, ...state.customProfiles].some((profile) => profile.name.toLowerCase() === name.toLowerCase())) {
    input.setCustomValidity("A profile with this name already exists.");
    input.reportValidity();
    return;
  }
  state.customProfiles.push({ id: `custom-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`, name, description: "Your custom battle controls, saved locally and ready when you are.", settings: { ...state.settings } });
  state.profile = name;
  input.value = "";
  render();
  renderProfiles();
  log(`Saved "${name}" profile.`);
  notify("Your custom profile is ready.");
});
$("#profile-name").addEventListener("input", () => $("#profile-name").setCustomValidity(""));
$("#clear-log").addEventListener("click", () => {
  state.events = [];
  renderLog();
  saveState();
  notify("Session log cleared.");
});
$("#motion-toggle").addEventListener("click", () => {
  state.reducedMotion = !state.reducedMotion;
  render();
  log(`Reduced motion ${state.reducedMotion ? "enabled" : "disabled"}.`);
});
$("#clear-data").addEventListener("click", () => {
  showDialog('<h2>A completely fresh start?</h2><p>This removes your custom profiles and activity, and restores the training preset. This cannot be undone.</p><div class="dialog-actions"><button class="button" id="cancel-reset">Keep workspace</button><button class="button primary" id="confirm-reset">Reset workspace</button></div>');
  $("#cancel-reset").addEventListener("click", () => $("#info-dialog").close());
  $("#confirm-reset").addEventListener("click", () => {
    state = { settings: { ...defaults }, profile: "Training preset", customProfiles: [], reducedMotion: false, events: [] };
    preview = { health: 100, ki: 100, skill: 3 };
    render();
    renderProfiles();
    log("Workspace reset. Training defaults restored.");
    $("#info-dialog").close();
    notify("Fresh workspace. Ready for the next round.");
  });
});

const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)");
function animatePreview(time) {
  const interval = state.settings.fps && state.settings.frameRate ? 1000 / state.settings.frameRate : 0;
  if (time - lastFrame >= interval) {
    lastFrame = interval ? time - ((time - lastFrame) % interval) : time;
    if (menuVisible && !$("#page-control-room").hidden && !document.hidden) {
      const motion = !state.reducedMotion && !motionPreference.matches;
      const scale = motion ? 1.018 + Math.sin(time / 4500) * 0.008 : 1.018;
      $(".hero-art").style.transform = `scale(${scale})`;
      $(".hero").classList.toggle("is-hit", time < hitUntil);
      $(".live-dot").style.opacity = motion ? String(0.65 + Math.sin(time / 700) * 0.35) : "1";
    }
  }
  requestAnimationFrame(animatePreview);
}
requestAnimationFrame(animatePreview);
