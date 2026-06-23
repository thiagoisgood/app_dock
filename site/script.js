(function () {
  var repo = "thiagoisgood/app_dock";
  var releasesApi = "https://api.github.com/repos/" + repo + "/releases?per_page=10";
  var releasesPage = "https://github.com/" + repo + "/releases";
  var siteDmgDownload = "downloads/app_dock.dmg";
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));

  function showAll() {
    reveals.forEach(function (node) {
      node.classList.add("is-visible");
    });
  }

  function allByData(name) {
    return Array.prototype.slice.call(document.querySelectorAll("[data-" + name + "]"));
  }

  function setText(name, value) {
    allByData(name).forEach(function (node) {
      node.textContent = value;
    });
  }

  function setHref(name, value) {
    allByData(name).forEach(function (node) {
      node.setAttribute("href", value);
    });
  }

  function formatCount(value) {
    if (typeof value !== "number") return value;
    return value.toLocaleString("zh-CN");
  }

  function formatBytes(value) {
    if (typeof value !== "number" || value <= 0) return "--";
    var units = ["B", "KB", "MB", "GB"];
    var size = value;
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size = size / 1024;
      index += 1;
    }
    return (index === 0 ? size : size.toFixed(1)) + " " + units[index];
  }

  function formatDate(value) {
    if (!value) return "--";
    var date = new Date(value);
    if (Number.isNaN(date.getTime())) return "--";
    return date.toISOString().slice(0, 10);
  }

  function selectRelease(releases) {
    var visible = releases.filter(function (release) {
      return !release.draft;
    });
    var releaseWithDmg = visible.find(function (release) {
      return (release.assets || []).some(function (asset) {
        return /\.dmg$/i.test(asset.name || "");
      });
    });
    return releaseWithDmg || visible[0] || null;
  }

  function selectAsset(release) {
    if (!release || !release.assets || !release.assets.length) return null;
    return release.assets.find(function (asset) {
      return /\.dmg$/i.test(asset.name || "");
    }) || null;
  }

  function applyRelease(release, asset) {
    var hasDmgAsset = asset && asset.browser_download_url;
    var downloadUrl = hasDmgAsset ? asset.browser_download_url : siteDmgDownload;
    var downloadCount = hasDmgAsset && typeof asset.download_count === "number"
      ? formatCount(asset.download_count)
      : "Release 后统计";

    setHref("release-download", downloadUrl);
    setHref("release-link", release.html_url || releasesPage);
    setText("release-count", downloadCount);
    setText("release-version", release.tag_name || release.name || "Latest");
    setText("release-status", hasDmgAsset ? (release.prerelease ? "公开预览版" : "公开发布版") : "站点 DMG 可下载");
    setText("release-filename", hasDmgAsset && asset.name ? asset.name : "app_dock.dmg");
    setText("release-size", hasDmgAsset ? formatBytes(asset.size) : "5.0 MB");
    setText("release-date", formatDate(release.published_at || release.created_at));
  }

  function applyNoReleaseState() {
    setHref("release-download", siteDmgDownload);
    setHref("release-link", releasesPage);
    setText("release-count", "Release 后统计");
    setText("release-version", "main / public preview");
    setText("release-status", "站点 DMG 可下载");
    setText("release-filename", "app_dock.dmg");
    setText("release-size", "5.0 MB");
    setText("release-date", "site/downloads");
  }

  function applyNetworkFallback() {
    setHref("release-download", siteDmgDownload);
    setHref("release-link", releasesPage);
    setText("release-count", "GitHub 暂不可用");
    setText("release-version", "main / public preview");
    setText("release-status", "站点 DMG 可下载");
    setText("release-filename", "app_dock.dmg");
    setText("release-size", "5.0 MB");
    setText("release-date", "site/downloads");
  }

  function loadReleaseStats() {
    if (!("fetch" in window)) {
      applyNetworkFallback();
      return;
    }

    fetch(releasesApi, {
      headers: { Accept: "application/vnd.github+json" }
    })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("GitHub API " + response.status);
        }
        return response.json();
      })
      .then(function (releases) {
        if (!Array.isArray(releases) || releases.length === 0) {
          applyNoReleaseState();
          return;
        }
        var release = selectRelease(releases);
        if (!release) {
          applyNoReleaseState();
          return;
        }
        applyRelease(release, selectAsset(release));
      })
      .catch(function () {
        applyNetworkFallback();
      });
  }

  if (!("IntersectionObserver" in window)) {
    showAll();
  } else {
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );

    reveals.forEach(function (node) {
      observer.observe(node);
    });

    window.setTimeout(function () {
      reveals.slice(0, 3).forEach(function (node) {
        node.classList.add("is-visible");
      });
    }, 120);

    window.setTimeout(showAll, 700);
  }

  loadReleaseStats();
})();
