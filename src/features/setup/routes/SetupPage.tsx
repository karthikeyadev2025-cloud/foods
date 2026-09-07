import { Link, Navigate, NavLink, useParams } from 'react-router-dom';
import { Wand2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { SETUP_STEPS } from '../steps';

/** Setup: one tab per configuration screen. Same components as the wizard. */
export function SetupPage() {
  const { tab } = useParams();
  const current = SETUP_STEPS.find((s) => s.slug === tab);
  if (!tab) return <Navigate to={`/setup/${SETUP_STEPS[0]?.slug ?? 'org'}`} replace />;
  if (!current) return <Navigate to="/setup" replace />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-semibold">Setup</h1>
        <Button asChild variant="outline" size="sm">
          <Link to="/setup/wizard">
            <Wand2 /> Run the setup wizard
          </Link>
        </Button>
      </div>
      <nav aria-label="Setup sections" className="flex flex-wrap gap-1 border-b">
        {SETUP_STEPS.map((s) => (
          <NavLink
            key={s.slug}
            to={`/setup/${s.slug}`}
            className={({ isActive }) =>
              cn(
                '-mb-px border-b-2 px-3 py-1.5 text-sm',
                isActive
                  ? 'border-primary font-medium text-primary'
                  : 'border-transparent text-muted-foreground hover:text-foreground',
              )
            }
          >
            {s.label}
          </NavLink>
        ))}
      </nav>
      <current.Component />
    </div>
  );
}
