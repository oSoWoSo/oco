// Search every rendered section, including code; no external/fetched search index.
document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('manual-search');
    if (!form) return;
    const input = document.getElementById('manual-query');
    const clear = document.getElementById('manual-clear');
    const status = document.getElementById('manual-search-status');
    const results = document.getElementById('manual-results');
    const list = document.getElementById('manual-result-list');
    const reading = document.getElementById('manual-reading');
    const chapters = [...document.querySelectorAll('.manual-section')].map(section => ({
        id: section.id,
        title: section.dataset.title,
        text: section.textContent.replace(/\s+/g, ' ').trim(),
    }));

    function search() {
        const query = input.value.trim().toLocaleLowerCase();
        const words = query.split(/\s+/).filter(Boolean);
        list.replaceChildren();
        results.hidden = !query;
        reading.hidden = Boolean(query);
        clear.hidden = !input.value;
        if (!query) {
            status.textContent = 'Search chapter titles and text.';
            return;
        }
        const matches = chapters.filter(chapter => words.every(word => `${chapter.title} ${chapter.text}`.toLocaleLowerCase().includes(word)));
        status.textContent = matches.length
            ? `${matches.length} matching ${matches.length === 1 ? 'chapter' : 'chapters'}.`
            : 'No matching chapters. Try “build_style”, “depends”, or “patches”.';
        if (!matches.length) {
            const item = document.createElement('li');
            item.textContent = 'No results. Try fewer words, or clear the search to browse all chapters.';
            list.append(item);
        }
        for (const chapter of matches) {
            const item = document.createElement('li');
            const link = document.createElement('a');
            link.href = `#${chapter.id}`;
            link.textContent = chapter.title;
            const excerpt = document.createElement('p');
            const position = chapter.text.toLocaleLowerCase().indexOf(words[0]);
            const start = Math.max(0, position - 65);
            excerpt.textContent = `${start ? '…' : ''}${chapter.text.slice(start, start + 220)}${chapter.text.length > start + 220 ? '…' : ''}`;
            item.append(link, excerpt);
            list.append(item);
        }
    }

    function revealChapter(event) {
        const link = event.target.closest('a[href^="#"]');
        if (!link) return;
        const target = document.getElementById(link.hash.slice(1));
        if (!target) return;
        // Reveal before the shared main.js smooth-scroll handler sees this link.
        event.preventDefault();
        event.stopPropagation();
        input.value = '';
        search();
        history.replaceState(null, '', link.hash);
        target.tabIndex = -1;
        target.focus({ preventScroll: true });
        target.scrollIntoView({ behavior: 'auto', block: 'start' });
    }

    form.hidden = false;
    form.addEventListener('submit', event => { event.preventDefault(); search(); });
    form.addEventListener('reset', event => {
        event.preventDefault();
        input.value = '';
        search();
        input.focus();
    });
    input.addEventListener('input', search);
    document.querySelector('.manual-layout').addEventListener('click', revealChapter, true);
    document.addEventListener('keydown', event => {
        const editing = event.target.closest('input, textarea, select, [contenteditable]');
        if (event.key === '/' && !editing && !event.ctrlKey && !event.metaKey && !event.altKey) {
            event.preventDefault();
            input.focus();
        }
        if (event.key === 'Escape' && document.activeElement === input) {
            input.value = '';
            search();
        }
    });
    window.addEventListener('hashchange', () => {
        if (location.hash) {
            input.value = '';
            search();
            document.getElementById(location.hash.slice(1))?.scrollIntoView();
        }
    });
});
