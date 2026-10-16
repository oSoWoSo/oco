// Shared navigation and theme behavior also supports pages without package search.
document.addEventListener('DOMContentLoaded', () => {
    const navToggle = document.querySelector('.nav-toggle');
    const navMenu = document.querySelector('.nav-menu');
    const spans = navToggle ? navToggle.querySelectorAll('span') : [];

    // The package-page templates use .nav-toggle on the theme button's wrapper,
    // not a hamburger. Only initialize a mobile menu when its markup exists.
    if (navToggle && navMenu && spans.length >= 3) {
        function updateNavigation(open) {
            navMenu.classList.toggle('active', open);
            spans[0].style.transform = open ? 'rotate(45deg) translate(6px, 6px)' : 'none';
            spans[1].style.opacity = open ? '0' : '1';
            spans[2].style.transform = open ? 'rotate(-45deg) translate(6px, -6px)' : 'none';
        }
        navToggle.addEventListener('click', () => updateNavigation(!navMenu.classList.contains('active')));
        navMenu.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => updateNavigation(false));
        });
    }

    initTheme();

    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', event => {
            const target = document.getElementById(anchor.getAttribute('href').slice(1));
            if (target) {
                event.preventDefault();
                target.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    });
});

function initTheme() {
    const currentTheme = localStorage.getItem('theme') || 'dark';
    document.documentElement.setAttribute('data-theme', currentTheme);
    updateThemeIcon(currentTheme);

    const themeToggle = document.querySelector('.theme-toggle');
    // Existing templates already call the global toggleTheme() inline.
    if (themeToggle && !themeToggle.hasAttribute('onclick')) {
        themeToggle.addEventListener('click', toggleTheme);
    }
}

function toggleTheme() {
    const currentTheme = document.documentElement.getAttribute('data-theme');
    const newTheme = currentTheme === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', newTheme);
    localStorage.setItem('theme', newTheme);
    updateThemeIcon(newTheme);
}

function updateThemeIcon(theme) {
    const lightIcon = document.querySelector('.theme-toggle .light-icon');
    const darkIcon = document.querySelector('.theme-toggle .dark-icon');
    if (lightIcon && darkIcon) {
        lightIcon.classList.toggle('active', theme === 'dark');
        darkIcon.classList.toggle('active', theme !== 'dark');
    }
}

// Search the same package tables visitors can browse: no separate index to go stale.
document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('package-search-form');
    if (!form) return;

    const input = document.getElementById('package-query');
    const clear = document.getElementById('package-search-clear');
    const status = document.getElementById('package-search-status');
    const results = document.getElementById('package-search-results');
    const hint = status.textContent;
    const architectures = [...document.querySelectorAll('nav a[data-package-arch]')];
    let indexPromise;
    let packages = [];
    let unavailable = [];
    let timer;
    let revision = 0;

    function tableRows(page) {
        const table = page.querySelector('#packages + table');
        if (!table) throw new Error('Package table unavailable');
        return [...table.querySelectorAll('tbody tr')];
    }

    // Deep links work without altering the generated table markup.
    const selected = new URL(window.location.href).searchParams.get('package');
    if (selected && document.querySelector('#packages + table')) {
        const row = tableRows(document).find(row => row.cells[0]?.textContent.trim() === selected);
        if (row) {
            row.classList.add('package-search-target');
            row.tabIndex = -1;
            row.focus({ preventScroll: true });
            row.scrollIntoView({ block: 'center' });
        }
    }

    async function loadIndex() {
        const entries = new Map();
        unavailable = [];
        await Promise.all(architectures.map(async link => {
            const arch = link.dataset.packageArch;
            const url = new URL(link.href, window.location.href);
            try {
                let page = document;
                const current = new URL(window.location.href);
                if (url.pathname.replace(/index\.html$/, '') !== current.pathname.replace(/index\.html$/, '')) {
                    const controller = new AbortController();
                    const timeout = setTimeout(() => controller.abort(), 10000);
                    try {
                        const response = await fetch(url, { signal: controller.signal });
                        if (!response.ok) throw new Error('Package page unavailable');
                        page = new DOMParser().parseFromString(await response.text(), 'text/html');
                    } finally {
                        clearTimeout(timeout);
                    }
                }
                for (const row of tableRows(page)) {
                    if (row.cells.length !== 5) continue;
                    const name = row.cells[0].textContent.trim();
                    const version = row.cells[1].textContent.trim();
                    const description = row.cells[4].textContent.trim();
                    const key = JSON.stringify([name, version, description]);
                    const homepage = row.cells[2].querySelector('a')?.href || '';
                    if (!entries.has(key)) entries.set(key, { name, version, description, homepage, architectures: [] });
                    const pkg = entries.get(key);
                    if (!pkg.homepage) pkg.homepage = homepage;
                    const target = new URL(url);
                    target.searchParams.set('package', name);
                    pkg.architectures.push({ arch, url: target.href });
                }
            } catch (_) {
                unavailable.push(arch);
            }
        }));
        packages = [...entries.values()].sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
        packages.forEach(pkg => pkg.architectures.sort((a, b) => a.arch.localeCompare(b.arch)));
        // A subsequent search retries unavailable pages rather than caching a failure forever.
        if (unavailable.length) indexPromise = null;
    }

    async function search() {
        const request = ++revision;
        const query = input.value.trim();
        clear.hidden = !input.value;
        results.replaceChildren();
        results.hidden = true;
        if (!query) {
            status.textContent = hint;
            return;
        }
        status.textContent = 'Loading package lists…';
        if (!indexPromise) indexPromise = loadIndex();
        await indexPromise;
        if (request !== revision) return;

        const words = query.toLocaleLowerCase().split(/\s+/);
        const matches = packages.filter(pkg => {
            const text = `${pkg.name} ${pkg.description}`.toLocaleLowerCase();
            return words.every(word => text.includes(word));
        }).sort((a, b) => Number(b.name.toLocaleLowerCase() === query.toLocaleLowerCase()) - Number(a.name.toLocaleLowerCase() === query.toLocaleLowerCase()));
        const fragment = document.createDocumentFragment();
        for (const pkg of matches) {
            const item = document.createElement('li');
            const heading = document.createElement('div');
            const name = document.createElement('strong');
            name.textContent = pkg.name;
            const version = document.createElement('span');
            version.className = 'package-search-version';
            version.textContent = pkg.version;
            heading.append(name, version);
            const description = document.createElement('p');
            description.textContent = pkg.description;
            const references = document.createElement('div');
            references.className = 'package-search-references';
            const templateLink = document.createElement('a');
            templateLink.href = `https://codeberg.org/osowoso/oco/src/branch/OCO/srcpkgs/${encodeURIComponent(pkg.name)}/template`;
            templateLink.textContent = 'Template (Codeberg)';
            references.append(templateLink);
            const githubLink = document.createElement('a');
            githubLink.href = `https://github.com/oSoWoSo/oco/blob/OCO/srcpkgs/${encodeURIComponent(pkg.name)}/template`;
            githubLink.textContent = 'GitHub fallback';
            references.append(githubLink);
            if (pkg.homepage) {
                const homepageLink = document.createElement('a');
                homepageLink.href = pkg.homepage;
                homepageLink.textContent = 'Project homepage';
                homepageLink.rel = 'noopener noreferrer';
                references.append(homepageLink);
            }
            const links = document.createElement('div');
            links.className = 'package-search-architectures';
            for (const target of pkg.architectures) {
                const link = document.createElement('a');
                link.href = target.url;
                link.textContent = target.arch;
                link.setAttribute('aria-label', `${pkg.name} ${pkg.version} on ${target.arch}`);
                links.append(link);
            }
            item.append(heading, description, references, links);
            fragment.append(item);
        }
        results.append(fragment);
        results.hidden = !matches.length;
        const summary = matches.length ? `${matches.length} package result${matches.length === 1 ? '' : 's'} for “${query}”. Choose an architecture to view a package.` : `No packages found for “${query}”. Try a different name or fewer words.`;
        status.textContent = unavailable.length === architectures.length
            ? 'Package lists could not be loaded. Search again to retry, or browse an architecture above.'
            : summary + (unavailable.length ? ` Results are incomplete: ${unavailable.sort().join(', ')} could not be loaded. Search again to retry.` : '');
    }

    form.hidden = false;
    input.addEventListener('input', () => {
        ++revision;
        clear.hidden = !input.value;
        clearTimeout(timer);
        timer = setTimeout(search, 180);
    });
    form.addEventListener('submit', event => {
        event.preventDefault();
        clearTimeout(timer);
        search();
    });
    function reset() {
        clearTimeout(timer);
        input.value = '';
        search();
        input.focus();
    }
    clear.addEventListener('click', reset);
    input.addEventListener('keydown', event => {
        if (event.key === 'Escape') {
            event.preventDefault();
            reset();
        }
    });
});
