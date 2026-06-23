(function () {
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));

  function showAll() {
    reveals.forEach(function (node) {
      node.classList.add("is-visible");
    });
  }

  if (!("IntersectionObserver" in window)) {
    showAll();
    return;
  }

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
})();
