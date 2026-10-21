// Folds the sidebar to icons and back. The choice is kept in a cookie so the
// server renders the page already folded; htmx swaps only <body>, so the class
// on <html> survives moving between pages.
document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-nav-toggle]");
  if (!button) return;
  const mini = document.documentElement.classList.toggle("nav-mini");
  document.cookie = `office_nav=${mini ? "mini" : "full"}; path=/administrator/; max-age=31536000; samesite=lax`;
  button.setAttribute("aria-pressed", String(mini));
});
