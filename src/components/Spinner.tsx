import { Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';

export function Spinner({ label = 'Loading…', full = false }: { label?: string; full?: boolean }) {
  return (
    <div
      role="status"
      aria-live="polite"
      className={cn('flex items-center gap-2 text-sm text-muted-foreground', full && 'min-h-screen justify-center')}
    >
      <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
      {label}
    </div>
  );
}
