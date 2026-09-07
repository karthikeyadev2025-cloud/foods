import { Check, ChevronLeft, ChevronRight } from 'lucide-react';
import { Link, Navigate, useNavigate, useParams } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { SETUP_STEPS } from '../steps';

/**
 * First-run wizard. A brand-new org must be configurable end to end here, with no
 * SQL. Each step is the same screen that lives under Setup afterwards.
 */
export function SetupWizard() {
  const { step } = useParams();
  const navigate = useNavigate();
  const index = step ? SETUP_STEPS.findIndex((s) => s.slug === step) : 0;
  if (index < 0) return <Navigate to="/setup/wizard" replace />;
  const current = SETUP_STEPS[index];
  if (!current) return <Navigate to="/setup" replace />;
  const prev = SETUP_STEPS[index - 1];
  const next = SETUP_STEPS[index + 1];

  return (
    <div className="mx-auto max-w-5xl space-y-4">
      <div>
        <h1 className="text-xl font-semibold">Set up JYOTHI FOODS</h1>
        <p className="text-sm text-muted-foreground">
          Step {index + 1} of {SETUP_STEPS.length}. Everything here can be changed later under Setup.
        </p>
      </div>

      <ol className="flex flex-wrap gap-1" aria-label="Steps">
        {SETUP_STEPS.map((s, i) => (
          <li key={s.slug}>
            <Link
              to={`/setup/wizard/${s.slug}`}
              aria-current={i === index ? 'step' : undefined}
              className={cn(
                'flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs',
                i === index
                  ? 'border-primary bg-primary text-primary-foreground'
                  : i < index
                    ? 'border-primary/40 text-primary'
                    : 'text-muted-foreground',
              )}
            >
              {i < index ? <Check className="h-3 w-3" aria-hidden /> : <span>{i + 1}</span>}
              {s.label}
            </Link>
          </li>
        ))}
      </ol>

      <div className="rounded-lg border bg-card p-4">
        <p className="mb-3 text-sm text-muted-foreground">{current.why}</p>
        <current.Component compact />
      </div>

      <div className="flex items-center justify-between">
        <Button variant="outline" disabled={!prev} onClick={() => prev && navigate(`/setup/wizard/${prev.slug}`)}>
          <ChevronLeft /> Back
        </Button>
        {next ? (
          <Button onClick={() => navigate(`/setup/wizard/${next.slug}`)}>
            Next: {next.label} <ChevronRight />
          </Button>
        ) : (
          <Button onClick={() => navigate('/')}>
            <Check /> Finish
          </Button>
        )}
      </div>
    </div>
  );
}
