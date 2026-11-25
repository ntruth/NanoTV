/* 拾光 Luma — 官网交互
   仅使用原生 API：滚动出现、视差、显示形式演示、搜索示例、对比筛选、复制命令。 */

(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.documentElement.classList.add("js");

  /* ---------- 滚动出现 ---------- */
  var revealItems = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var revealObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          revealObserver.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });

    revealItems.forEach(function (el) { revealObserver.observe(el); });

    // 同组卡片错峰出现
    document.querySelectorAll(".source-grid, .bento, .memory-strip, .privacy-grid, .stats-grid").forEach(function (group) {
      var kids = group.querySelectorAll(":scope > .reveal");
      kids.forEach(function (kid, i) { kid.style.setProperty("--delay", (i * 70) + "ms"); });
    });
  } else {
    revealItems.forEach(function (el) { el.classList.add("is-visible"); });
  }

  /* ---------- 导航状态与阅读进度 ---------- */
  var nav = document.getElementById("siteNav");
  var progress = document.getElementById("navProgress");
  var navToggle = document.getElementById("navToggle");
  var navMobile = document.getElementById("navMobile");

  function setMenu(open) {
    if (!navToggle || !navMobile) return;
    navMobile.classList.toggle("is-open", open);
    navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    navToggle.setAttribute("aria-label", open ? "关闭导航菜单" : "打开导航菜单");
  }

  if (navToggle && navMobile) {
    navToggle.addEventListener("click", function () {
      setMenu(navToggle.getAttribute("aria-expanded") !== "true");
    });
    navMobile.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () { setMenu(false); });
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setMenu(false);
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 900) setMenu(false);
    });
  }

  function onScroll() {
    var y = window.scrollY || window.pageYOffset;
    if (nav) nav.classList.toggle("is-scrolled", y > 16);
    if (progress) {
      var max = document.documentElement.scrollHeight - window.innerHeight;
      progress.style.width = (max > 0 ? Math.min(100, (y / max) * 100) : 0) + "%";
    }
    if (y > 90 && navMobile && navMobile.classList.contains("is-open")) setMenu(false);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- Hero 视差 ---------- */
  var stage = document.getElementById("heroStage");
  var win = document.getElementById("tiltWindow");
  if (stage && win && !reduceMotion && window.matchMedia("(pointer: fine)").matches) {
    stage.addEventListener("mousemove", function (e) {
      var rect = stage.getBoundingClientRect();
      var px = (e.clientX - rect.left) / rect.width - 0.5;
      var py = (e.clientY - rect.top) / rect.height - 0.5;
      win.style.setProperty("--ry", (px * 4).toFixed(2) + "deg");
      win.style.setProperty("--rx", (5 - py * 3).toFixed(2) + "deg");
    });
    stage.addEventListener("mouseleave", function () {
      win.style.setProperty("--ry", "0deg");
      win.style.setProperty("--rx", "5deg");
    });
  }

  /* ---------- 显示形式演示 ---------- */
  var demoGrid = document.getElementById("demoGrid");
  var demoLabel = document.getElementById("demoLabel");
  var demoButtons = document.querySelectorAll(".demo-btn");
  var layoutNames = {
    square: "正方形裁剪",
    aspect: "完整宽高比",
    waterfall: "瀑布流",
    list: "列表"
  };

  demoButtons.forEach(function (btn) {
    btn.addEventListener("click", function () {
      var layout = btn.getAttribute("data-layout");
      if (!demoGrid || !layout) return;
      if (demoGrid.getAttribute("data-layout") === layout) return;
      demoGrid.setAttribute("data-layout", layout);
      demoButtons.forEach(function (b) {
        var on = b === btn;
        b.classList.toggle("is-on", on);
        b.setAttribute("aria-selected", on ? "true" : "false");
      });
      if (demoLabel) demoLabel.textContent = layoutNames[layout] || layout;
      if (!reduceMotion && demoGrid.animate) {
        demoGrid.animate(
          [{ opacity: .25, transform: "translateY(6px)" }, { opacity: 1, transform: "none" }],
          { duration: 240, easing: "cubic-bezier(.22,1,.36,1)" }
        );
      }
    });
  });

  /* ---------- 智能搜索示例 ---------- */
  var typed = document.getElementById("typedQuery");
  var chips = document.getElementById("searchChips");
  var count = document.getElementById("resultCount");
  var resultGrid = document.querySelector(".result-grid");

  var samples = [
    {
      text: "去年 海边 狗",
      chips: [["chip-time", "时间 · 去年"], ["chip-scene", "场景 · 海边"], ["chip-object", "对象 · 狗"]],
      count: "找到 3 个结果",
      shots: ["s2", "s8", "s3"]
    },
    {
      text: "2024年5月 日落",
      chips: [["chip-time", "时间 · 2024 年 5 月"], ["chip-scene", "场景 · 日落"]],
      count: "找到 42 个结果",
      shots: ["s1", "s4", "s11"]
    },
    {
      text: "上个月 小猫",
      chips: [["chip-time", "时间 · 上个月"], ["chip-scene", "场景 · 猫"], ["chip-object", "对象 · 动物"]],
      count: "找到 8 个结果",
      shots: ["s5", "s6", "s9"]
    },
    {
      text: "有文字的截图",
      chips: [["chip-scene", "类型 · 截图"], ["chip-object", "内容 · 包含文字"]],
      count: "找到 16 个结果",
      shots: ["s7", "s10", "s12"]
    }
  ];

  function paintSample(sample) {
    if (chips) {
      chips.innerHTML = sample.chips.map(function (pair) {
        return '<span class="' + pair[0] + '">' + pair[1] + "</span>";
      }).join("");
    }
    if (count) count.textContent = sample.count;
    if (resultGrid) {
      resultGrid.querySelectorAll("figure").forEach(function (fig, i) {
        fig.className = "shot " + (sample.shots[i] || "s1");
      });
    }
  }

  if (typed && chips && count && !reduceMotion) {
    var sampleIndex = 0;
    var charIndex = 0;
    var deleting = false;
    var timer = null;
    var started = false;

    function sleep(ms) {
      return new Promise(function (resolve) { timer = setTimeout(resolve, ms); });
    }

    async function runTyping() {
      await sleep(900);
      while (!document.hidden) {
        var sample = samples[sampleIndex];
        var text = sample.text;

        if (!deleting) {
          charIndex++;
          typed.textContent = text.slice(0, charIndex);
          if (charIndex >= text.length) {
            paintSample(sample);
            await sleep(2100);
            deleting = true;
            continue;
          }
          await sleep(95);
        } else {
          charIndex--;
          typed.textContent = text.slice(0, charIndex);
          if (charIndex <= 0) {
            deleting = false;
            sampleIndex = (sampleIndex + 1) % samples.length;
            await sleep(520);
            continue;
          }
          await sleep(38);
        }
      }
    }

    var typeObserver = new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting && !started) {
        started = true;
        runTyping();
        typeObserver.disconnect();
      }
    }, { threshold: 0.3 });
    typeObserver.observe(typed);
  }

  /* ---------- 对比筛选与移动端标签 ---------- */
  var table = document.getElementById("compareTable");
  if (table) {
    var heads = Array.prototype.map.call(table.querySelectorAll("thead th"), function (th) {
      return th.textContent.trim();
    });
    table.querySelectorAll("tbody tr").forEach(function (row) {
      Array.prototype.forEach.call(row.children, function (cell, index) {
        if (index > 0) cell.setAttribute("data-label", index === 1 ? "照片" : "拾光");
      });
    });

    document.querySelectorAll(".cmp-tab").forEach(function (tab) {
      tab.addEventListener("click", function () {
        var cat = tab.getAttribute("data-cat");
        document.querySelectorAll(".cmp-tab").forEach(function (t) {
          var on = t === tab;
          t.classList.toggle("is-on", on);
          t.setAttribute("aria-selected", on ? "true" : "false");
        });
        table.querySelectorAll("tbody tr").forEach(function (row) {
          var show = cat === "all" || row.getAttribute("data-cat") === cat;
          row.classList.toggle("is-hidden", !show);
        });
      });
    });
  }

  /* ---------- 复制命令 ---------- */
  var toast = document.getElementById("toast");
  var toastTimer = null;
  function showToast(message) {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("is-on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.remove("is-on"); }, 1900);
  }

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var value = btn.getAttribute("data-copy") || "";
      if (!value) return;
      var done = function () { showToast("已复制：" + value); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(done, function () { showToast("复制失败，请手动选择"); });
      } else {
        showToast("请手动选择命令复制");
      }
    });
  });

  /* ---------- 回忆示例按钮 ---------- */
  var playBtn = document.querySelector("[data-demo-play]");
  if (playBtn) {
    playBtn.addEventListener("click", function () {
      var bar = document.querySelector(".memory-progress i");
      if (bar && !reduceMotion) {
        bar.style.animation = "none";
        void bar.offsetWidth;
        bar.style.animation = "memprog 8s linear infinite";
      }
      showToast("回忆播放与导出在应用内完成，本页为交互示意");
    });
  }

  /* ---------- 页内锚点偏移（固定导航） ---------- */
  document.querySelectorAll('a[href^="#"]').forEach(function (link) {
    link.addEventListener("click", function (e) {
      var id = link.getAttribute("href");
      if (!id || id === "#") return;
      var target = document.querySelector(id);
      if (!target) return;
      e.preventDefault();
      var top = target.getBoundingClientRect().top + window.scrollY - 68;
      window.scrollTo({ top: top, behavior: reduceMotion ? "auto" : "smooth" });
      history.replaceState(null, "", id);
    });
  });
})();
