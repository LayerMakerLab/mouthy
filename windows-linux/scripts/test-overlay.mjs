import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// Run the shipped overlay script against Tauri events and a controllable clock. No app, microphone or display.
const html = readFileSync(new URL('../app/frontend/overlay.html', import.meta.url), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function overlay() {
    const events = new Map(), timers = new Map();
    let now = 0, nextID = 0, writes = 0, frames = 0;
    class Element {
        children = [];
        events = new Map();
        textContent = '';
        classes = new Set();
        classList = {
            add: (...names) => names.forEach(name => this.classes.add(name)),
            remove: (...names) => names.forEach(name => this.classes.delete(name)),
            contains: name => this.classes.has(name),
            toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
        };
        style = new Proxy({ setProperty() {} }, { set: (target, key, value) => { writes++; target[key] = value; return true; } });
        appendChild(element) { this.children.push(element); }
        addEventListener(name, handler) { this.events.set(name, handler); }
    }
    const elements = Object.fromEntries(['island', 'wave', 'dot', 'mark', 'time'].map(id => [id, new Element()]));
    const document = {
        hidden: false, body: new Element(), events: new Map(),
        getElementById: id => elements[id], createElement: () => new Element(),
        addEventListener(name, handler) { this.events.set(name, handler); },
    };
    const context = vm.createContext({
        document, Number, Math, String, Array,
        performance: { now: () => now },
        setTimeout: (callback, delay) => { const id = ++nextID; timers.set(id, { callback, at: now + delay }); return id; },
        clearTimeout: id => timers.delete(id),
        requestAnimationFrame: () => { frames++; },
        window: { __TAURI__: { event: { listen: (name, callback) => events.set(name, callback) }, core: { invoke: async () => 'Idle' } } },
    });
    vm.runInContext(source, context);
    return {
        elements, document, timers,
        get writes() { return writes; }, get frames() { return frames; },
        emit: (name, payload) => events.get(name)({ payload }),
        hover: active => elements.island.events.get(active ? 'mouseenter' : 'mouseleave')(),
        hidden(value) { document.hidden = value; document.events.get('visibilitychange')(); },
        advance(milliseconds) {
            const end = now + milliseconds;
            for (;;) {
                const next = [...timers.entries()].filter(([, value]) => value.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
                if (!next) break;
                const [id, value] = next; timers.delete(id); now = value.at; value.callback();
            }
            now = end;
        },
    };
}

test('voice bars update on audio events and rest without a JavaScript frame loop', () => {
    const app = overlay();
    app.emit('phase', 'Listening');
    assert.equal(app.elements.wave.children.length, 9);
    app.emit('level', 0.64);
    const tall = app.elements.wave.children[4].style.transform;
    app.emit('level', 0);
    assert.notEqual(app.elements.wave.children[4].style.transform, tall);
    const writes = app.writes;
    for (let i = 0; i < 200; i++) app.emit('level', 0);
    app.advance(10_000);
    assert.equal(app.writes, writes, 'repeated silence never rewrites layer styles');
    assert.equal(app.timers.size, 0, 'the hidden clock does not wake the webview');
    assert.equal(app.frames, 0, 'the compositor owns continuous animation');
    app.emit('phase', 'Finishing');
    assert.ok(app.elements.wave.classList.contains('finishing'));
    app.emit('phase', 'Idle');
    app.advance(200);
    assert.ok(!app.elements.island.classList.contains('shown'));
    assert.equal(app.timers.size, 0);
});

test('elapsed time wakes once a second only while visible on hover', () => {
    const app = overlay();
    app.emit('phase', 'Listening');
    app.advance(3_250); app.hover(true);
    assert.equal(app.elements.time.textContent, '0:03');
    assert.equal(app.timers.size, 1);
    app.advance(750);
    assert.equal(app.elements.time.textContent, '0:04');
    app.hidden(true);
    assert.equal(app.timers.size, 0);
    app.advance(59_000); app.hidden(false);
    assert.equal(app.elements.time.textContent, '1:03');
    app.hover(false);
    assert.equal(app.timers.size, 0);
});

test('a restarted recording cannot be hidden by the previous outcome timer', () => {
    const app = overlay();
    app.emit('phase', 'Listening'); app.emit('phase', 'Finishing');
    app.emit('status', 'Copied to clipboard.'); app.emit('phase', 'Idle');
    app.advance(100); app.emit('phase', 'Listening'); app.advance(1_000);
    assert.ok(app.elements.island.classList.contains('shown'));
    assert.equal(app.elements.wave.style.display, 'flex');
    assert.equal(app.timers.size, 0);
});

test('hidden and invalid level events cannot cause repaint churn or invalid transforms', () => {
    const app = overlay();
    app.emit('phase', 'Listening'); app.hidden(true);
    const writes = app.writes;
    app.emit('level', 0.81);
    assert.equal(app.writes, writes);
    app.hidden(false);
    for (const value of [NaN, Infinity, -1, undefined]) app.emit('level', value);
    for (const bar of app.elements.wave.children) assert.equal(bar.style.transform, 'scaleY(0.162)');
});
