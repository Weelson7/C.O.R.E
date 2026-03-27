# C.O.R.E. Style Guidelines

## 1. Purpose

This document defines the visual and motion system for C.O.R.E. interfaces.

It must be applied whenever possible:

- in direct frontend implementation,
- via component libraries,
- through plugins/themes,
- or by post-build rewrite steps.

If exact implementation is blocked by platform constraints, preserve the same semantics (color meaning, hierarchy, and motion intent).

## 2. Creative Direction

Primary direction: **deep purple operations UI with controlled neon shimmer**.

Desired feeling:

- Secure
- High-availability
- Technical
- Alive but disciplined

Visual metaphor:

- Dark matter base + electric telemetry signals.

### 2.1 Brand Mark Asset

Canonical logo asset:

- `Branding/logo.png`

Usage rules:

1. Treat `Branding/logo.png` as the single source of truth for the C.O.R.E. mark.
2. Preserve aspect ratio at all sizes.
3. Keep clear space around the mark equal to at least the height of the letter "O" in the logo.
4. Do not recolor the logo in ways that break the deep-purple neon system.
5. Prefer placing the logo on dark surfaces (`--background-base`, `--primary-dark`, `--primary-medium`) for best contrast.

## 3. Design Tokens

Use these as source-of-truth tokens in CSS variables, theme JSON, Tailwind config, or design system primitives.

### 3.1 Core Palette

```css
:root {
	/* Base surfaces */
	--background-base: #080812;
	--background-elev-1: #0d0d1a;
	--background-elev-2: #130a2b;
	--surface-card: #1a0a3d;
	--surface-card-alt: #14082f;

	/* Brand purples */
	--primary-dark: #0d0d1a;
	--primary-medium: #1a0a3d;
	--primary-bright: #3a156d;
	--accent-neon: #b44fff;
	--accent-dim: #7a2fb5;
	--accent-shimmer: #d28bff;
	--accent-glow: rgba(180, 79, 255, 0.25);

	/* Typography */
	--text-primary: #f1e6ff;
	--text-secondary: #c8addf;
	--text-muted: #9f87b6;
	--text-disabled: #6f6283;

	/* Semantic status */
	--status-success: #39ff8a;
	--status-info: #56c7ff;
	--status-warn: #ffc14d;
	--status-error: #ff4466;
	--status-offline: #cd0d30;

	/* Utility */
	--border-subtle: rgba(180, 79, 255, 0.25);
	--border-strong: rgba(180, 79, 255, 0.6);
	--shadow-soft: 0 4px 20px rgba(0, 0, 0, 0.45);
	--shadow-neon: 0 0 22px rgba(180, 79, 255, 0.35);
}
```

### 3.2 Color Usage Rules

1. Purple shades define structure and brand identity.
2. Green/yellow/red are reserved for health semantics.
3. Do not use red for decorative accents.
4. Do not use success green for buttons unrelated to successful state.
5. Maintain minimum contrast ratio of 4.5:1 for normal text.

## 4. Typography

Preferred stack:

- UI/Body: "Inter", "Segoe UI", sans-serif
- Mono/Telemetry: "JetBrains Mono", "Consolas", monospace

Typographic behavior:

- Headings: slightly condensed spacing, medium-to-bold weights.
- Body text: neutral line-height, avoid dense blocks.
- Data labels and node IDs: mono font.

## 5. Layout and Surfaces

### 5.1 Page Background

Use layered gradients, not flat fills.

```css
background:
	radial-gradient(1200px 700px at 85% -10%, rgba(180, 79, 255, 0.12), transparent 60%),
	radial-gradient(900px 500px at -10% 110%, rgba(122, 47, 181, 0.16), transparent 65%),
	linear-gradient(135deg, var(--background-base) 0%, var(--primary-medium) 100%);
```

### 5.2 Cards and Panels

- Card base: dark purple gradient.
- Border: dim neon purple.
- Hover: increase border intensity and glow.
- Keep corners medium (10-14px); avoid ultra-round style.

## 6. Components

### 6.1 Header

- Horizontal purple gradient background.
- Neon bottom border.
- Soft ambient glow under header edge.

### 6.2 Service Cards

States:

- default: dim border + subtle shadow
- hover: brighter border + elevated glow
- focused: visible focus ring (2px info blue)
- selected: extra inner highlight line

### 6.3 Status Dots

- online: success green + small glow
- degraded: amber + intermittent pulse
- down/offline: red + stronger pulse
- unknown: muted violet, no pulse

### 6.4 Banners

- info: info blue border and icon
- warning: amber border, no heavy animation
- critical: red border + short attention pulse for first 3 seconds only

## 7. Motion System

Motion exists to communicate state transitions and hierarchy changes.

### 7.1 Motion Principles

1. Short and meaningful; default duration 140ms-240ms.
2. No infinite motion on large surfaces.
3. Any persistent animation must run at low amplitude.
4. Reduce motion for critical reading moments.

### 7.2 Easing

- enter: `cubic-bezier(0.22, 1, 0.36, 1)`
- exit: `cubic-bezier(0.4, 0, 1, 1)`
- status pulse: `ease-in-out`

### 7.3 Animation Scenarios

#### Scenario A: Page load

- Header fades in + slight upward reveal (180ms)
- Cards stagger in (30ms between cards, max 8 cards staggered)
- Background shimmer starts after content settles (delay 400ms)

#### Scenario B: Card hover

- Border color transitions to accent-neon (120ms)
- Shadow grows softly (140ms)
- Optional 1-pass shimmer sweep on title edge (220ms)

#### Scenario C: Service goes degraded

- Dot changes to amber immediately
- Card border gains amber tint for 1.2s then returns to normal
- Small warning chip appears with fade/slide (160ms)

#### Scenario D: Service goes down

- Dot flips to red instantly
- Card performs single micro-shake (1 cycle, <= 240ms)
- Critical banner appears at top with urgency pulse limited to 3 loops

#### Scenario E: Failover completed

- Affected cards receive cyan "rerouted" tag
- Old node label fades out; new node label crossfades in (200ms)
- Success green confirmation pulse once, then static

#### Scenario F: Recovery to healthy

- Red/amber indicator transitions to green over 180ms
- Warning/critical chips collapse with height animation (160ms)
- Card returns to baseline glow, no celebratory excess

### 7.4 Reduced Motion Support

```css
@media (prefers-reduced-motion: reduce) {
	* {
		animation-duration: 1ms !important;
		animation-iteration-count: 1 !important;
		transition-duration: 1ms !important;
		scroll-behavior: auto !important;
	}
}
```

## 8. Shimmer and Neon Rules

Shimmer should simulate reflected light, not glitter.

Allowed shimmer locations:

- Header edge
- Card top border
- Primary action button outline

Avoid shimmer on:

- Body text
- Dense tables
- Error paragraphs

Reference shimmer effect:

```css
.shimmer-line {
	position: relative;
	overflow: hidden;
}

.shimmer-line::after {
	content: "";
	position: absolute;
	inset: 0;
	transform: translateX(-120%);
	background: linear-gradient(
		100deg,
		transparent 20%,
		rgba(210, 139, 255, 0.35) 45%,
		rgba(210, 139, 255, 0.7) 50%,
		rgba(210, 139, 255, 0.35) 55%,
		transparent 80%
	);
	animation: shimmer-pass 2.6s ease-in-out infinite;
}

@keyframes shimmer-pass {
	0%, 60% { transform: translateX(-120%); }
	100% { transform: translateX(120%); }
}
```

## 9. Status and Incident Semantics

Apply this mapping in all dashboards and plugins.

| State | Color | Motion | Meaning |
|---|---|---|---|
| healthy | `--status-success` | no pulse or very soft pulse | service reachable and stable |
| info | `--status-info` | none | informational transition |
| degraded | `--status-warn` | slow pulse | partial impairment |
| critical/down | `--status-error` | short urgent pulse | unavailable or failing checks |
| failover-active | `--accent-neon` + optional cyan tag | one-time transition | traffic rerouted |

## 10. Accessibility and Quality Bars

Minimum requirements:

1. Keyboard-visible focus on all interactive elements.
2. Text contrast >= 4.5:1; large text >= 3:1.
3. Color is never the only status cue (use icon/text labels too).
4. Animations do not block interaction.
5. Important alerts persist long enough to be read.

## 11. Implementation Modes

If full redesign is impossible, apply in this priority order:

1. Token replacement (`:root` variables)
2. Status semantic mapping
3. Header/card gradients + border glow
4. Motion scenarios for status changes
5. Optional shimmer enhancements

This allows plugin/theme-based rewrites while preserving brand integrity.

## 12. Copy and Micro-UI Tone

Labels should be operational and clear.

Use:

- "Online"
- "Degraded"
- "Failover active"
- "Manual action required"

Avoid:

- "Oops"
- "Uh oh"
- "Something broke"

## 13. Definition of Done for C.O.R.E. Styling

A UI implementation is considered compliant when:

1. Purple-neon token system is present and consistent.
2. Status colors and states follow this document.
3. Motion scenarios are implemented for load, incident, failover, and recovery.
4. Shimmer is subtle and restricted to approved surfaces.
5. Accessibility checks pass for contrast and reduced motion.

If these are true, the interface is visually and behaviorally aligned with the C.O.R.E. brand.
