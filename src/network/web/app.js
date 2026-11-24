const byId = (id) => document.getElementById(id);
const token = window.location.pathname.split("/").filter(Boolean).pop();
const languageButtons = document.querySelectorAll("[data-language]");
let language = "en";
try { if (localStorage.getItem("batllm-language") === "es") language = "es"; } catch (_) {}
let currentState = null;
let connection = "connecting";
let stateError = null;
let notice = null;
let submitting = false;

function t(key) {
  return translations[language][key] || translations.en[key] || translations[language].stateError;
}

function renderBot(bot) {
  const node = byId("bot-" + bot.id);
  node.style.left = (bot.x * 100) + "%";
  node.style.top = (bot.y * 100) + "%";
  node.querySelector(".arrow").style.transform = "rotate(" + bot.rot + "deg)";
  node.classList.toggle("shield", bot.shield);
  node.querySelector(".bot-tag").textContent = "Bot " + bot.id;
  byId("health-" + bot.id).textContent = bot.health + " HP";
  byId("position-" + bot.id).textContent = "X: " + bot.x.toFixed(3) + " · Y: " + bot.y.toFixed(3);
  byId("rotation-" + bot.id).textContent = t("rotation") + ": " + bot.rot.toFixed(0) + "°";
  byId("shield-" + bot.id).textContent = t("shield") + ": " + t(bot.shield ? "on" : "off");
  byId("command-" + bot.id).textContent = t("lastCommand") + ": " + (bot.last_cmd || "—");
}

function render() {
  document.documentElement.lang = language;
  document.querySelectorAll("[data-i18n]").forEach(node => {
    node.textContent = t(node.dataset.i18n);
  });
  byId("languages").setAttribute("aria-label", t("language"));
  byId("arena").setAttribute("aria-label", t("arena"));
  languageButtons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.language === language)));
  byId("connection").textContent = t(connection);
  byId("prompt-label").textContent = t("instructions");
  byId("submit").textContent = t("submit");
  byId("notice").textContent = notice ? t(notice) : "";
  for (const id of [1, 2]) {
    byId("name-" + id).textContent = t("player") + " " + id;
    byId("command-" + id).textContent = t("lastCommand") + ": —";
    byId("ready-" + id).textContent = t("noPrompt");
  }
  let disabled = true;
  let status = t("waitingState");
  if (!currentState) {
    byId("identity").textContent = t("connectingGame");
    for (const key of ["game", "round", "turn", "model"]) byId(key).textContent = t(key) + " —";
  } else {
    const state = currentState;
    const me = state.players.find(player => player.id === state.player_id);
    const opponent = state.players.find(player => player.id !== state.player_id);
    byId("identity").textContent = t("identity") + " " + state.player_id;
    byId("game").textContent = t("game") + " " + state.game;
    byId("round").textContent = t("round") + " " + state.round + " / " + state.total_rounds;
    byId("turn").textContent = state.round_active
      ? t("turn") + " " + Math.min(state.turn + 1, state.turns_per_round) + " / " + state.turns_per_round
      : t("waitingRound");
    byId("model").textContent = t("model") + ": " + (state.model || "Ollama");
    state.bots.forEach(renderBot);
    state.players.forEach(player => {
      byId("player-" + player.id).classList.toggle("active", player.id === state.player_id);
      byId("ready-" + player.id).textContent = t(player.ready ? "received" : "noPrompt");
    });
    status = state.phase === "running" ? t("running")
      : me.ready ? t("waitingOpponent").replace("{id}", opponent.id)
      : t(opponent.ready ? "opponentReady" : "waitingPrompts");
    disabled = state.phase === "running" || me.ready;
  }
  byId("status").textContent = stateError ? t(stateError) : status;
  disabled = disabled || submitting || connection !== "connected";
  byId("prompt").disabled = disabled;
  byId("submit").disabled = disabled;
}

languageButtons.forEach(button => button.addEventListener("click", () => {
  language = button.dataset.language;
  try { localStorage.setItem("batllm-language", language); } catch (_) {}
  render();
}));

function errorKey(payload, fallback) {
  const key = payload.error_code;
  return Object.hasOwn(translations.en, key) ? key : fallback;
}

async function refresh() {
  try {
    const response = await fetch("/api/v1/state/" + encodeURIComponent(token), { cache: "no-store" });
    const payload = await response.json();
    if (!response.ok) {
      stateError = errorKey(payload, "stateError");
      connection = "disconnected";
    } else {
      currentState = payload;
      stateError = null;
      connection = "connected";
    }
  } catch (_) {
    stateError = "stateError";
    connection = "disconnected";
  } finally {
    render();
    window.setTimeout(refresh, 800);
  }
}

byId("prompt-form").addEventListener("submit", async event => {
  event.preventDefault();
  const prompt = byId("prompt").value;
  if (!prompt.trim() || !currentState || submitting || byId("submit").disabled) return;
  submitting = true;
  notice = "sending";
  render();
  try {
    const response = await fetch("/api/v1/prompts/" + encodeURIComponent(token), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt })
    });
    const payload = await response.json();
    if (!response.ok) {
      notice = errorKey(payload, "submitError");
    } else {
      byId("prompt").value = "";
      notice = null;
        connection = "connecting";
    }
  } catch (_) {
    notice = "submitError";
  } finally {
    submitting = false;
    render();
  }
});

byId("help-button").addEventListener("click", () => byId("help-dialog").showModal());

render();
refresh();
