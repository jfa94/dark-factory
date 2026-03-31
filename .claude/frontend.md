# Frontend Guidelines

## Preferred Tech Stack

- **Frontend:** TypeScript, React, Next.js (App Router), Tailwind CSS
- **Database:** Supabase
- **Authentication:** Supabase Auth
- **Analytics:** PostHog
- **Payments:** Stripe
- **Icons:** Lucide

## Architecture

- Store reusable components that are shared between pages in a `src/components/` folder and page-specific components in a directory next to the `page.tsx` file (e.g., `src/app/dashboard/components/`)
- Co-locate component tests: `Button.tsx` → `Button.test.tsx`

## Frontend Coding Standards

- TypeScript strict mode with noUncheckedIndexedAccess enabled
- Use `globals.css` for global styles only, not component/page-specific styles.
- Next.js Server functions return `[data, error]` tuples:
    ```ts
    Promise<[T | null, Error | null]>
    ```

## Tailwind Guidelines

- Reuse existing `globals.css` classes instead of duplicating.
- Class order: layout, box model, background, borders, typography, effects, filters, transitions/animations, transforms, interactivity, SVG.
- Responsive classes start with base class and follow increasing screen sizes (e.g., `w-full md:w-1/2 lg:w-1/3`).

## React Guidelines

- Use function-based React components with arrow functions for callbacks.
- Define prop types as a separate interface above the component:
    ```tsx
    interface ButtonProps {
        text: string
    }
    const Button = ({text}: ButtonProps) => {
        // component code
    }
    ```
- Never import services directly from components — use hooks or server actions
