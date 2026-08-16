/* Погодный сервис — frontend (тема «Янтарная ночь»). */
(function () {
  "use strict";

  var AUTO_REFRESH_MS = 20 * 60 * 1000; // 20 минут

  var cities = [];           // [{id,name,alias,latitude,longitude,timezone}]
  var weatherByCity = {};    // city_id -> weather data
  var lastUpdatedAt = null;  // unix ms — время последнего успешного обновления
  var loading = false;
  var debounceTimer = null;
  var pendingRefresh = false;

  var state = {
    user: null,         // username или null (гость)
    enabled: null,      // Set включённых city_id для пользователя; null у гостя
    displayMode: "compact",  // "compact" | "full"
    cityFilter: "all"        // "all" | "selected" | "selected_first"
  };
  var allCitiesCache = [];
  var settingsSearchQuery = "";
  var settingsSearchTimer = null;
  var searchNoteTimer = null;
  var authMode = "login";  // "login" | "register"

  var els = {};
  function $(id) { return document.getElementById(id); }

  // ---- emoji / helpers -------------------------------------------------
  var CONDITION_EMOJI = {
    "Ясно": "☀️", "Преим. ясно": "🌤", "Облачно": "⛅", "Пасмурно": "☁️",
    "Туман": "🌫", "Гололёд": "🌫",
    "Слабая морось": "🌦", "Морось": "🌦", "Сильная морось": "🌦",
    "Ледяная крупа": "🌦", "Ледяной дождь": "🌦",
    "Небольшой дождь": "🌧", "Дождь": "🌧", "Ливень": "🌧",
    "Дождь с гололёдом": "🌧", "Сильный гололёд": "🌧",
    "Неб. снег": "🌨", "Снег": "🌨", "Снегопад": "🌨", "Снежная крупа": "🌨",
    "Неб. ливень": "🌧", "Сильный ливень": "🌧",
    "Сильный снег": "🌨",
    "Гроза": "⛈", "Гроза с градом": "⛈", "Ураган": "⛈",
    "Нет данных": "❓"
  };

  function weatherEmoji(code, condition) {
    if (code != null) {
      if (code === 0) return "☀️";
      if (code === 1) return "🌤";
      if (code === 2) return "⛅";
      if (code === 3) return "☁️";
      if (code === 45 || code === 48) return "🌫";
      if (code >= 51 && code <= 57) return "🌦";
      if (code >= 61 && code <= 67) return "🌧";
      if (code >= 71 && code <= 77) return "🌨";
      if (code >= 80 && code <= 82) return "🌧";
      if (code === 85 || code === 86) return "🌨";
      if (code >= 95 && code <= 99) return "⛈";
    }
    if (condition) return CONDITION_EMOJI[condition] || "❓";
    return "❓";
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtVal(v, suffix) {
    if (v == null || v === "") return "—";
    return String(v) + (suffix || "");
  }

  function fmtClock(ts) {
    if (!ts) return "—";
    var d = new Date(ts);
    var h = d.getHours(), m = d.getMinutes();
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m;
  }

  function fmtCountdown(ms) {
    var sec = Math.max(0, Math.round(ms / 1000));
    if (sec >= 60) {
      return "через " + Math.floor(sec / 60) + " мин";
    }
    return "через " + sec + " сек";
  }

  // ---- API -------------------------------------------------------------
  function api(path, opts) {
    return fetch(path, opts).then(function (res) {
      return res.json().then(function (data) {
        if (!res.ok) {
          var err = new Error(data && data.error ? data.error : ("HTTP " + res.status));
          err.status = res.status;
          err.data = data;
          throw err;
        }
        return data;
      });
    });
  }

  // ---- loading / status ------------------------------------------------
  function setStatus(text, cls) {
    els.status.textContent = text || "";
    els.status.className = "status" + (cls ? " " + cls : "");
  }

  function renderStatus() {
    if (els.status.classList.contains("error")) return;
    if (lastUpdatedAt == null) {
      setStatus("");
      return;
    }
    var remaining = AUTO_REFRESH_MS - (Date.now() - lastUpdatedAt);
    var tail = remaining <= 0 ? "обновление…" : fmtCountdown(remaining);
    setStatus("Обновлено: " + fmtClock(lastUpdatedAt) + " · следующее обновление " + tail, "ok");
  }

  function showLoading() {
    loading = true;
    if (lastUpdatedAt == null) setStatus("Загрузка…");
    els.cards.innerHTML = '<div class="spinner">(ᛉ)</div>';
  }

  function hideLoading() {
    loading = false;
  }

  // ---- render ----------------------------------------------------------
  function visibleCities() {
    var set = state.enabled;
    if (!set) return cities;   // гость — все города
    var mode = state.cityFilter || "all";
    if (mode === "selected") {
      return cities.filter(function (c) { return set.has(c.id); });
    }
    if (mode === "selected_first") {
      var enabled = [], rest = [];
      for (var i = 0; i < cities.length; i++) {
        (set.has(cities[i].id) ? enabled : rest).push(cities[i]);
      }
      return enabled.concat(rest);
    }
    return cities;
  }

  function renderCards() {
    if (loading) return;
    els.cards.innerHTML = "";
    var vis = visibleCities();
    if (!vis.length) {
      els.cards.classList.remove("full");
      els.cards.innerHTML = '<p class="status" style="color:var(--dim)">' +
        (state.user ? "Включите города в настройках." : "Добавьте город через поиск.") +
        '</p>';
      return;
    }
    // Один видимый город всегда показываем полностью, независимо от настройки.
    var full = vis.length === 1 || state.displayMode === "full";
    els.cards.classList.toggle("full", full);
    for (var i = 0; i < vis.length; i++) {
      els.cards.appendChild(renderCard(vis[i], full));
    }
  }

  function renderCard(city, full) {
    var data = weatherByCity[city.id];
    var card = document.createElement("div");
    card.className = "card";

    if (!data) {
      card.innerHTML =
        '<div class="card-name">' + esc(city.name) + '</div>' +
        '<div class="spinner" style="font-size:34px;padding:16px 0">(ᛉ)</div>';
      return card;
    }

    if (full) {
      card.classList.add("card-full");
      card.innerHTML = fullCardHTML(city, data);
    } else {
      var c = data.current || {};
      var d = data.daily || {};
      var emoji = weatherEmoji(c.weather_code, c.condition);

      card.innerHTML =
        '<div class="card-name">' + esc(city.name) + '</div>' +
        '<div class="card-emoji">' + emoji + '</div>' +
        '<div class="card-temp">' + fmtVal(c.temperature, "°") + '</div>' +
        '<div class="card-condition">' + esc(c.condition || "") + '</div>' +
        '<div class="card-rows">' +
          row("Ощущается", fmtVal(c.feels_like, "°")) +
          row("Влажность", fmtVal(c.humidity, "%")) +
          row("Ветер", (c.wind_direction || "") + " " + fmtVal(c.wind_speed, " м/с")) +
          row("Давление", fmtVal(c.pressure_mmhg, " мм рт. ст.")) +
        '</div>' +
        '<div class="card-sun">' +
          '<span>☀ ' + esc(d.sunrise || "—") + '</span>' +
          '<span>☾ ' + esc(d.sunset || "—") + '</span>' +
        '</div>';
    }

    card.addEventListener("click", function () { openModal(city); });
    return card;
  }

  function row(label, value) {
    return '<div class="row"><span class="label">' + esc(label) + '</span>' +
           '<span>' + esc(value) + '</span></div>';
  }

  // ---- modal -----------------------------------------------------------
  // Полная сводка (блоки Сейчас / Сегодня / Ночь). Используется и в модалке,
  // и для полноформатных карточек в full-режиме.
  function fullCardHTML(city, data, metaHtml) {
    var c = data.current || {};
    var d = data.daily || {};
    var n = data.nightly || {};

    var emoji = weatherEmoji(c.weather_code, c.condition);

    return '<h2>' + esc(data.name || city.name) + '</h2>' +
      '<div class="modal-emoji">' + emoji + '</div>' +
      (metaHtml || "") +

      '<div class="section">' +
        '<h3>Сейчас</h3>' +
        detail("Температура", fmtVal(c.temperature, "°")) +
        detail("Ощущается", fmtVal(c.feels_like, "°")) +
        detail("Влажность", fmtVal(c.humidity, "%")) +
        detail("Давление", fmtVal(c.pressure_mmhg, " мм рт. ст.")) +
        detail("Ветер", (c.wind_direction || "") + " " + fmtVal(c.wind_speed, " м/с")) +
        detail("Осадки", fmtVal(c.precipitation, " мм")) +
        detail("Облачность", fmtVal(c.cloud_cover, "%")) +
        detail("Состояние", esc(c.condition || "—")) +
      '</div>' +

      '<div class="section">' +
        '<h3>Сегодня</h3>' +
        detail("Макс. / мин.", fmtVal(d.temp_max, "°") + " / " + fmtVal(d.temp_min, "°")) +
        detail("Осадки", fmtVal(d.precipitation_sum, " мм")) +
        detail("Вероятность осадков", fmtVal(d.precipitation_probability, "%")) +
        detail("Восход / закат", esc(d.sunrise || "—") + " / " + esc(d.sunset || "—")) +
        detail("Преобладающий ветер", (d.wind_direction_dominant || "") +
          " " + fmtVal(d.wind_speed_max, " м/с")) +
      '</div>' +

      '<div class="section">' +
        '<h3>Ночь</h3>' +
        detail("Мин. / макс.", fmtVal(n.temperature_min, "°") + " / " + fmtVal(n.temperature_max, "°")) +
        detail("Давление", fmtVal(n.pressure_mmhg, " мм рт. ст.")) +
        detail("Осадки", fmtVal(n.precipitation_sum, " мм")) +
        detail("Вероятность осадков", fmtVal(n.precipitation_probability, "%")) +
        detail("Ветер", (n.wind_direction_dominant || "") + " " + fmtVal(n.wind_speed_max, " м/с")) +
        detail("Состояние", esc(n.condition || "—")) +
      '</div>' +

      '<div class="updated">' + esc(data.updated_at || "") + '</div>';
  }

  function openModal(city) {
    var data = weatherByCity[city.id];
    if (!data) return;

    var metaHtml =
      '<div class="meta">ID города: <a href="#" class="copy-id" title="Скопировать ссылку API">' +
      esc(data.city_id) + '</a><br>' +
      'Часовой пояс: <strong>' + esc(data.timezone || "—") + '</strong></div>';

    els.modalBody.innerHTML = fullCardHTML(city, data, metaHtml);
    var idLink = els.modalBody.querySelector(".copy-id");
    if (idLink) {
      idLink.addEventListener("click", function (e) {
        e.preventDefault();
        e.stopPropagation();
        copyCityIdLink(data.city_id, idLink);
      });
    }
    els.modalContent.classList.remove("single");
    showModal();
  }

  function detail(label, value) {
    return '<div class="detail"><span class="label">' + esc(label) + '</span>' +
           '<span class="value">' + esc(value) + '</span></div>';
  }

  // ---- copy to clipboard (works on plain HTTP LAN) --------------------
  function legacyCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "-9999px";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    try {
      ta.select();
      ta.setSelectionRange(0, text.length);
      return document.execCommand("copy");
    } catch (e) {
      return false;
    } finally {
      document.body.removeChild(ta);
    }
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () {
        if (legacyCopy(text)) return;
        throw new Error("copy failed");
      });
    }
    return legacyCopy(text)
      ? Promise.resolve()
      : Promise.reject(new Error("copy failed"));
  }

  function copyCityIdLink(cityId, el) {
    var url = window.location.origin + "/api/weather?city_id=" + cityId;
    copyText(url).then(function () {
      var original = el.textContent;
      el.textContent = "Ссылка скопирована";
      el.classList.add("copied");
      setTimeout(function () {
        el.textContent = original;
        el.classList.remove("copied");
      }, 1500);
    }).catch(function () {
      setStatus("Не удалось скопировать ссылку", "error");
    });
  }

  function closeModal() {
    els.modal.classList.add("hidden");
    document.body.style.overflow = "";
  }

  function showModal() {
    els.modal.classList.remove("hidden");
    document.body.style.overflow = "hidden";
  }

  // ---- data loading ----------------------------------------------------
  function loadCities() {
    return api("/api/cities").then(function (data) {
      cities = data.cities || [];
      return cities;
    });
  }

  function fetchOne(cityId, refresh) {
    var url = "/api/weather?city_id=" + encodeURIComponent(cityId);
    if (refresh) url += "&refresh=1";
    return api(url).then(function (data) {
      weatherByCity[cityId] = data;
      return { ok: true, cityId: cityId };
    }).catch(function (err) {
      return { ok: false, cityId: cityId, error: err };
    });
  }

  function loadWeather(refresh) {
    var vis = visibleCities();
    if (!vis.length) {
      renderCards();
      return Promise.resolve();
    }
    var jobs = vis.map(function (c) { return fetchOne(c.id, refresh); });
    return Promise.all(jobs).then(function (results) {
      var okCount = 0, failCount = 0;
      for (var i = 0; i < results.length; i++) {
        if (results[i].ok) okCount++; else failCount++;
      }
      if (okCount > 0) lastUpdatedAt = Date.now();
      if (failCount > 0) {
        setStatus("Ошибка обновления для " + failCount + " городов (показаны старые данные)",
          "error");
      }
    });
  }

  function refreshAll(force) {
    if (loading) {
      pendingRefresh = true;
      return Promise.resolve();
    }
    showLoading();
    return loadCities()
      .then(function () { return loadWeather(force); })
      .catch(function () {
        setStatus("Не удалось загрузить список городов", "error");
      })
      .then(function () {
        hideLoading();
        renderCards();
        renderStatus();
        if (pendingRefresh) {
          pendingRefresh = false;
          refreshAll(force);
        }
      });
  }

  // ---- search ----------------------------------------------------------
  function onSearchInput() {
    var q = els.search.value.trim();
    clearTimeout(debounceTimer);
    if (!q) {
      els.results.classList.add("hidden");
      return;
    }
    debounceTimer = setTimeout(function () { runGeocode(q); }, 350);
  }

  function runGeocode(q) {
    api("/api/geocode?q=" + encodeURIComponent(q))
      .then(function (data) {
        renderResults(data.results || []);
      })
      .catch(function () {
        renderResults([]);
      });
  }

  function renderResults(results) {
    var list = els.results;
    list.innerHTML = "";
    if (!results.length) {
      var empty = document.createElement("li");
      empty.className = "empty";
      empty.textContent = "Ничего не найдено";
      list.appendChild(empty);
      list.classList.remove("hidden");
      return;
    }
    for (var i = 0; i < results.length; i++) {
      (function (r) {
        var li = document.createElement("li");
        var sub = [r.admin1, r.country].filter(Boolean).join(", ");
        li.innerHTML = '<div>' + esc(r.name) + '</div>' +
          (sub ? '<div class="sub">' + esc(sub) + '</div>' : '');
        li.addEventListener("click", function () { addCity(r); });
        list.appendChild(li);
      })(results[i]);
    }
    list.classList.remove("hidden");
  }

  function showSearchNote(text, cls) {
    var note = $("search-note");
    if (!note) return;
    note.textContent = text || "";
    note.className = "search-note" + (cls ? " " + cls : "");
    clearTimeout(searchNoteTimer);
    searchNoteTimer = setTimeout(function () {
      note.classList.add("hidden");
      note.textContent = "";
    }, 3000);
  }

  function addCity(r) {
    els.results.classList.add("hidden");
    var typed = els.search.value.trim();
    api("/api/cities", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: r.id,
        name: r.name,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }).then(function () {
      els.search.value = "";
      return syncEnabled().then(function () { return refreshAll(true); });
    }).catch(function (err) {
      els.search.value = typed;
      if (err.status === 409) {
        showSearchNote("Такой город уже есть", "error");
        setStatus("Город уже добавлен", "error");
      } else {
        setStatus("Не удалось добавить город", "error");
      }
      syncEnabled().then(function () { refreshAll(false); });
    });
  }

  // ---- auth ------------------------------------------------------------
  function renderAuth() {
    var el = els.authArea;
    el.innerHTML = "";
    if (state.user) {
      var name = document.createElement("span");
      name.className = "auth-user";
      name.textContent = state.user;
      el.appendChild(name);

      var settingsBtn = document.createElement("button");
      settingsBtn.type = "button";
      settingsBtn.id = "btn-settings";
      settingsBtn.className = "btn";
      settingsBtn.textContent = "Настройки";
      settingsBtn.addEventListener("click", openSettings);
      el.appendChild(settingsBtn);

      var logoutBtn = document.createElement("button");
      logoutBtn.type = "button";
      logoutBtn.id = "btn-logout";
      logoutBtn.className = "btn";
      logoutBtn.textContent = "Выйти";
      logoutBtn.addEventListener("click", logout);
      el.appendChild(logoutBtn);
    } else {
      var loginBtn = document.createElement("button");
      loginBtn.type = "button";
      loginBtn.id = "btn-auth";
      loginBtn.className = "btn";
      loginBtn.textContent = "Войти";
      loginBtn.addEventListener("click", openAuthModal);
      el.appendChild(loginBtn);
    }
  }

  function initAuth() {
    return api("/api/me").then(function (data) {
      state.user = data.user || null;
      state.enabled = new Set(data.cities || []);
      state.displayMode = data.display_mode || "compact";
      state.cityFilter = data.city_filter || "all";
      return state.user;
    }).catch(function () {
      state.user = null;
      state.enabled = null;
      state.displayMode = "compact";
      state.cityFilter = "all";
      return null;
    });
  }

  function syncEnabled() {
    if (!state.user) {
      state.enabled = null;
      state.displayMode = "compact";
      state.cityFilter = "all";
      return Promise.resolve();
    }
    return api("/api/me").then(function (data) {
      state.user = data.user || state.user;
      state.enabled = new Set(data.cities || []);
      state.displayMode = data.display_mode || "compact";
      state.cityFilter = data.city_filter || "all";
    }).catch(function () {
      state.enabled = new Set();
    });
  }

  function openAuthModal() {
    authMode = "login";
    renderAuthModal();
  }

  function renderAuthModal() {
    var isLogin = authMode === "login";
    var html =
      '<h2>' + (isLogin ? "Вход" : "Регистрация") + '</h2>' +
      '<form id="auth-form" class="auth-form">' +
        '<label class="field"><span>Имя</span>' +
          '<input id="auth-username" type="text" autocomplete="username" spellcheck="false" required></label>' +
        '<label class="field"><span>Пароль</span>' +
          '<input id="auth-password" type="password" autocomplete="' +
          (isLogin ? "current-password" : "new-password") + '" required></label>' +
        (isLogin ? "" :
          '<label class="field"><span>Повтор пароля</span>' +
            '<input id="auth-password2" type="password" autocomplete="new-password" required></label>') +
        '<div id="auth-error" class="auth-error hidden"></div>' +
        '<button type="submit" class="btn auth-submit">' +
          (isLogin ? "Войти" : "Зарегистрироваться") + '</button>' +
      '</form>' +
      '<p class="auth-switch">' +
        (isLogin
          ? 'Нет аккаунта? <a href="#" id="auth-switch">Создать</a>'
          : 'Уже есть аккаунт? <a href="#" id="auth-switch">Войти</a>') +
      '</p>';

    els.modalContent.classList.add("single");
    els.modalBody.innerHTML = html;
    showModal();

    els.modalBody.querySelector("#auth-form").addEventListener("submit", function (e) {
      e.preventDefault();
      submitAuth();
    });
    els.modalBody.querySelector("#auth-switch").addEventListener("click", function (e) {
      e.preventDefault();
      authMode = authMode === "login" ? "register" : "login";
      renderAuthModal();
    });
    var first = els.modalBody.querySelector("#auth-username");
    if (first) first.focus();
  }

  function showAuthError(msg) {
    var box = els.modalBody.querySelector("#auth-error");
    if (!box) return;
    box.textContent = msg;
    box.classList.remove("hidden");
  }

  function submitAuth() {
    var usernameEl = els.modalBody.querySelector("#auth-username");
    var passwordEl = els.modalBody.querySelector("#auth-password");
    var username = (usernameEl ? usernameEl.value : "").trim();
    var password = passwordEl ? passwordEl.value : "";

    if (authMode === "register") {
      var password2El = els.modalBody.querySelector("#auth-password2");
      if ((password2El ? password2El.value : "") !== password) {
        showAuthError("Пароли не совпадают");
        return;
      }
    }

    var url = authMode === "login" ? "/api/login" : "/api/register";
    api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: username, password: password })
    }).then(function (data) {
      state.user = data.user || null;
      closeModal();
      renderAuth();
      return syncEnabled().then(function () { return refreshAll(false); });
    }).catch(function (err) {
      var msg = "Не удалось выполнить действие";
      if (err.status === 409) msg = "Такое имя уже занято";
      else if (err.status === 401) msg = "Неверное имя или пароль";
      else if (err.status === 400) msg = "Имя от 3 символов, пароль от 6 символов";
      showAuthError(msg);
    });
  }

  function logout() {
    api("/api/logout", { method: "POST" }).then(function () {
      state.user = null;
      state.enabled = null;
      state.displayMode = "compact";
      state.cityFilter = "all";
      renderAuth();
      return refreshAll(false);
    }).catch(function () {
      state.user = null;
      state.enabled = null;
      state.displayMode = "compact";
      state.cityFilter = "all";
      renderAuth();
      refreshAll(false);
    });
  }

  // ---- settings --------------------------------------------------------
  function openSettings() {
    api("/api/all-cities").then(function (data) {
      allCitiesCache = data.cities || [];
      renderSettingsModal(allCitiesCache);
    }).catch(function () {
      setStatus("Не удалось загрузить настройки", "error");
    });
  }

  function settingsFilteredCities() {
    var q = settingsSearchQuery.trim().toLowerCase();
    if (!q) return allCitiesCache;
    return allCitiesCache.filter(function (c) {
      return String(c.name || "").toLowerCase().indexOf(q) !== -1;
    });
  }

  function renderSettList() {
    var list = els.modalBody.querySelector(".sett-list");
    if (!list) return;
    var enabled = state.enabled || new Set();
    var filtered = settingsFilteredCities();

    list.innerHTML = "";
    if (!allCitiesCache.length) {
      var p = document.createElement("p");
      p.className = "sett-empty";
      p.textContent = "Нет доступных городов.";
      list.appendChild(p);
      return;
    }
    if (!filtered.length) {
      var p2 = document.createElement("p");
      p2.className = "sett-empty";
      p2.textContent = "Ничего не найдено";
      list.appendChild(p2);
      return;
    }

    for (var i = 0; i < filtered.length; i++) {
      var c = filtered[i];
      var on = enabled.has(c.id);
      var label = document.createElement("label");
      label.className = "sett-row";
      label.innerHTML =
        '<span>' + esc(c.name) + '</span>' +
        '<input type="checkbox" class="sett-check" data-id="' + esc(c.id) + '"' +
        (on ? " checked" : "") + '>';
      list.appendChild(label);
      label.querySelector(".sett-check")
        .addEventListener("change", onToggleCity);
    }
  }

  function onSettingsSearchInput(e) {
    settingsSearchQuery = e.target.value;
    clearTimeout(settingsSearchTimer);
    settingsSearchTimer = setTimeout(renderSettList, 150);
  }

  function renderSettingsModal(allCities) {
    allCitiesCache = allCities || [];
    var html = '<h2>Настройки</h2>';

    // Отображение: кратко / полностью.
    html += '<div class="sett-section"><h3>Отображение</h3>' +
      '<div class="sett-options">' +
        '<label class="sett-radio">' +
          '<input type="radio" name="display_mode" value="compact"' +
          (state.displayMode !== "full" ? " checked" : "") + '>' +
          '<span>Кратко</span></label>' +
        '<label class="sett-radio">' +
          '<input type="radio" name="display_mode" value="full"' +
          (state.displayMode === "full" ? " checked" : "") + '>' +
          '<span>Полностью</span></label>' +
      '</div></div>';

    // Города: фильтр + поиск + список чекбоксов (в несколько колонок).
    html += '<div class="sett-section"><h3>Города</h3>' +
      '<div class="sett-options">' +
        '<label class="sett-radio">' +
          '<input type="radio" name="city_filter" value="all"' +
          (state.cityFilter === "all" ? " checked" : "") + '>' +
          '<span>Все города</span></label>' +
        '<label class="sett-radio">' +
          '<input type="radio" name="city_filter" value="selected"' +
          (state.cityFilter === "selected" ? " checked" : "") + '>' +
          '<span>Только выделенные</span></label>' +
        '<label class="sett-radio">' +
          '<input type="radio" name="city_filter" value="selected_first"' +
          (state.cityFilter === "selected_first" ? " checked" : "") + '>' +
          '<span>Выделенные сверху</span></label>' +
      '</div>' +
      '<input type="text" id="sett-search" class="sett-search" ' +
        'placeholder="Поиск города…" autocomplete="off" spellcheck="false">' +
      '<div class="sett-list"></div></div>';

    els.modalContent.classList.add("single");
    els.modalBody.innerHTML = html;
    showModal();

    renderSettList();

    var searchEl = els.modalBody.querySelector("#sett-search");
    if (searchEl) {
      searchEl.value = settingsSearchQuery;
      searchEl.addEventListener("input", onSettingsSearchInput);
    }

    var dm = els.modalBody.querySelectorAll('input[name="display_mode"]');
    for (var k = 0; k < dm.length; k++) {
      dm[k].addEventListener("change", onDisplayModeChange);
    }

    var cf = els.modalBody.querySelectorAll('input[name="city_filter"]');
    for (var l = 0; l < cf.length; l++) {
      cf[l].addEventListener("change", onCityFilterChange);
    }
  }

  function onDisplayModeChange(e) {
    var mode = e.target.value;
    api("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ display_mode: mode })
    }).then(function () {
      state.displayMode = mode;
      renderCards();
    }).catch(function () {
      renderSettingsModal(allCitiesCache);
      setStatus("Не удалось сохранить настройку", "error");
    });
  }

  function onCityFilterChange(e) {
    var filt = e.target.value;
    api("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ city_filter: filt })
    }).then(function () {
      state.cityFilter = filt;
      refreshAll(false);
    }).catch(function () {
      renderSettingsModal(allCitiesCache);
      setStatus("Не удалось сохранить настройку", "error");
    });
  }

  function onToggleCity(e) {
    var checkbox = e.target;
    var cityId = parseInt(checkbox.getAttribute("data-id"), 10);
    var enabled = checkbox.checked;

    api("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ city_id: cityId, enabled: enabled })
    }).then(function () {
      if (state.enabled) {
        if (enabled) state.enabled.add(cityId);
        else state.enabled.delete(cityId);
      }
      refreshAll(false);
    }).catch(function () {
      checkbox.checked = !enabled;
      setStatus("Не удалось сохранить настройку", "error");
    });
  }

  // ---- events ----------------------------------------------------------
  function bindEvents() {
    els.refresh.addEventListener("click", function () {
      refreshAll(true);
    });

    els.search.addEventListener("input", onSearchInput);
    els.search.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        els.results.classList.add("hidden");
      }
    });

    document.addEventListener("click", function (e) {
      if (!els.searchWrap.contains(e.target)) {
        els.results.classList.add("hidden");
      }
    });

    els.modalClose.addEventListener("click", closeModal);
    els.modalOverlay.addEventListener("click", closeModal);
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeModal();
    });
  }

  function init() {
    els = {
      search: $("search"),
      searchWrap: document.querySelector(".search-wrap"),
      results: $("results"),
      refresh: $("refresh"),
      cards: $("cards"),
      status: $("status"),
      modal: $("modal"),
      modalOverlay: $("modal-overlay"),
      modalClose: $("modal-close"),
      modalContent: $("modal-content"),
      modalBody: $("modal-body"),
      authArea: $("auth-area")
    };
    bindEvents();
    renderAuth();
    initAuth()
      .then(function () { renderAuth(); return refreshAll(false); })
      .catch(function () { renderAuth(); return refreshAll(false); });
    setInterval(function () { refreshAll(false); }, AUTO_REFRESH_MS);
    setInterval(renderStatus, 1000);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
