/* 拾光 Luma — 使用手册交互：目录定位、章节搜索、打印。 */

(function () {
  "use strict";

  var tocLinks = Array.prototype.slice.call(document.querySelectorAll("#docToc a"));
  var chapters = Array.prototype.slice.call(document.querySelectorAll(".doc-chapter"));
  var hero = document.querySelector(".doc-hero");
  var searchInput = document.getElementById("docSearch");
  var emptyState = document.getElementById("searchEmpty");

  /* ---------- 目录高亮 ---------- */
  var linkById = {};
  tocLinks.forEach(function (link) {
    var id = (link.getAttribute("href") || "").replace("#", "");
    if (id) linkById[id] = link;
  });

  var ticking = false;
  function updateActive() {
    ticking = false;
    var y = window.scrollY + 110;
    var visible = chapters.filter(function (chapter) {
      return !chapter.classList.contains("is-search-hidden");
    });
    if (!visible.length) {
      tocLinks.forEach(function (link) { link.classList.remove("is-active"); });
      return;
    }
    var current = visible[0];
    visible.forEach(function (chapter) {
      if (chapter.offsetTop <= y) current = chapter;
    });
    if (!current) return;
    tocLinks.forEach(function (link) { link.classList.remove("is-active"); });
    var active = linkById[current.id];
    if (active) {
      active.classList.add("is-active");
      var toc = document.getElementById("docToc");
      if (toc) {
        var linkRect = active.getBoundingClientRect();
        var tocRect = toc.getBoundingClientRect();
        if (window.innerWidth <= 860) {
          if (linkRect.left < tocRect.left || linkRect.right > tocRect.right) {
            toc.scrollLeft += linkRect.left - tocRect.left - 16;
          }
        } else if (linkRect.top < tocRect.top || linkRect.bottom > tocRect.bottom) {
          toc.scrollTop += linkRect.top - tocRect.top - 40;
        }
      }
    }
  }
  function onScroll() {
    if (!ticking) {
      ticking = true;
      window.requestAnimationFrame(updateActive);
    }
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  updateActive();

  /* ---------- 章节搜索 ---------- */
  function applyFilter(query) {
    var q = query.trim().toLowerCase();
    var matched = 0;

    chapters.forEach(function (chapter) {
      var hit = !q || chapter.textContent.toLowerCase().indexOf(q) !== -1;
      chapter.classList.toggle("is-search-hidden", !hit);
      if (hit) matched++;

      var link = linkById[chapter.id];
      if (link) link.style.display = hit ? "" : "none";
    });

    // 目录分组标题：该组全部隐藏时也隐藏标题
    var toc = document.getElementById("docToc");
    if (toc) {
      var nodes = Array.prototype.slice.call(toc.children);
      nodes.forEach(function (node, index) {
        if (!node.classList || !node.classList.contains("toc-title")) return;
        var sibling = node.nextElementSibling;
        var anyVisible = false;
        while (sibling && !sibling.classList.contains("toc-title")) {
          if (sibling.style.display !== "none") anyVisible = true;
          sibling = sibling.nextElementSibling;
        }
        node.style.display = anyVisible ? "" : "none";
      });
    }

    if (hero) hero.classList.toggle("is-search-hidden", false);
    if (emptyState) emptyState.hidden = !q || matched > 0;
    updateActive();
  }

  if (searchInput) {
    searchInput.addEventListener("input", function () {
      applyFilter(searchInput.value);
    });
    searchInput.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        searchInput.value = "";
        applyFilter("");
        searchInput.blur();
      }
    });

    document.addEventListener("keydown", function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        searchInput.focus();
        searchInput.select();
      }
    });
  }

  /* ---------- 打印 ---------- */
  ["printDoc", "printDoc2"].forEach(function (id) {
    var btn = document.getElementById(id);
    if (btn) {
      btn.addEventListener("click", function (e) {
        e.preventDefault();
        window.print();
      });
    }
  });

  /* ---------- 锚点滚动偏移（兼容旧浏览器） ---------- */
  tocLinks.forEach(function (link) {
    link.addEventListener("click", function () {
      tocLinks.forEach(function (l) { l.classList.remove("is-active"); });
      link.classList.add("is-active");
    });
  });
})();
