import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { useState } from 'react';
import { Pager } from '@/components/Pager';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { dateTimeDMY, int, money } from '@/lib/format';
import { DEFAULT_PAGE_SIZE } from '@/lib/paging';
import { creditBalance, listAllCreditLedger, listCreditLedger, listTopups, type CreditRow } from '../api';

/**
 * Where the shop's message credits stand.
 *
 * The point of this screen is that the shop never has to take our word for the
 * number. The balance shown is the sum of the rows shown: every credit bought
 * and every credit spent is there with the date and what it was for, so "I
 * bought ten thousand, where are they" is a question they can answer by
 * reading, not by ringing us up. Which also means the figures here must not be
 * computed two different ways — the balance comes from the same ledger the
 * table lists.
 */

const PAYMENT_URL = (import.meta.env.VITE_CREDITS_PAYMENT_URL ?? '').trim();

/** How many credits went out in the last 30 days, from the rows we have. */
function spentRecently(rows: CreditRow[]): { spent: number; days: number } {
  const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
  let spent = 0;
  let earliest = Date.now();
  for (const r of rows) {
    if (r.delta >= 0) continue;
    const at = new Date(r.created_at).getTime();
    if (at < cutoff) continue;
    spent += -r.delta;
    earliest = Math.min(earliest, at);
  }
  // The window is however much history there actually is, so a shop two days
  // in is not told it uses 3 messages a day when it uses 45.
  const days = Math.max(1, Math.round((Date.now() - earliest) / (24 * 60 * 60 * 1000)));
  return { spent, days };
}

function reasonLabel(r: CreditRow): string {
  if (r.reason === 'message') return 'Message sent';
  if (r.reason === 'top-up') return 'Credits bought';
  if (r.reason === 'opening balance') return 'Opening balance';
  return r.reason;
}

export function CreditsPanel() {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);

  const balance = useQuery({ queryKey: ['credits', 'balance'], queryFn: creditBalance });
  const ledger = useQuery({
    queryKey: ['credits', 'ledger', { page, pageSize }],
    queryFn: () => listCreditLedger({ page, pageSize }),
    placeholderData: keepPreviousData,
  });
  const topups = useQuery({ queryKey: ['credits', 'topups'], queryFn: listTopups });
  // The usage figure needs more than one page of rows to mean anything.
  const recent = useQuery({ queryKey: ['credits', 'recent'], queryFn: listAllCreditLedger });

  const left = balance.data ?? 0;
  const usage = recent.data ? spentRecently(recent.data) : null;
  const perDay = usage && usage.spent > 0 ? usage.spent / usage.days : 0;
  const daysLeft = perDay > 0 ? Math.floor(left / perDay) : null;
  // What a credit last cost, so the screen quotes their price and not ours.
  const lastRate = topups.data?.find((t) => t.rate_paise > 0)?.rate_paise ?? null;

  const onExport = async () => {
    try {
      const rows = await listAllCreditLedger();
      exportToExcel(
        'message-credits',
        rows.map((r) => ({
          When: dateTimeDMY(r.created_at),
          What: reasonLabel(r),
          'In': r.delta > 0 ? r.delta : '',
          'Out': r.delta < 0 ? -r.delta : '',
          Note: r.note ?? '',
        })),
        'Credits',
      );
    } catch (err) {
      toastError(err, 'Export failed');
    }
  };

  return (
    <div className="space-y-4">
      {/* The three things a shop wants to know: how many left, how long that
          lasts, and how to buy more. */}
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-lg border p-4">
          <div className="text-xs uppercase tracking-wide text-muted-foreground">Credits left</div>
          <div className={`mt-1 text-3xl font-semibold tabular-nums ${left <= 0 ? 'text-destructive' : left < 100 ? 'text-amber-600' : ''}`}>
            {balance.isLoading ? <Spinner /> : int(left)}
          </div>
          <div className="mt-1 text-xs text-muted-foreground">
            {left <= 0
              ? 'Nothing is being sent. Messages are waiting, not lost.'
              : lastRate
                ? `1 credit = 1 message, at ${money(lastRate / 100)} each`
                : '1 credit = 1 message'}
          </div>
        </div>

        <div className="rounded-lg border p-4">
          <div className="text-xs uppercase tracking-wide text-muted-foreground">Being used</div>
          <div className="mt-1 text-3xl font-semibold tabular-nums">
            {recent.isLoading ? <Spinner /> : perDay > 0 ? int(Math.round(perDay)) : '—'}
          </div>
          <div className="mt-1 text-xs text-muted-foreground">
            {perDay > 0
              ? `a day on average${daysLeft !== null ? `, so about ${int(daysLeft)} day${daysLeft === 1 ? '' : 's'} left` : ''}`
              : 'no messages sent yet'}
          </div>
        </div>

        <div className="rounded-lg border p-4">
          <div className="text-xs uppercase tracking-wide text-muted-foreground">Buy more</div>
          {PAYMENT_URL ? (
            <>
              <Button asChild className="mt-2 h-8">
                <a href={PAYMENT_URL} target="_blank" rel="noreferrer">Pay and top up</a>
              </Button>
              <div className="mt-2 text-xs text-muted-foreground">Credits are added as soon as the payment goes through.</div>
            </>
          ) : (
            <div className="mt-2 text-xs text-muted-foreground">
              Credits are bought from Adexos Global Technologies. Scan the payment QR they sent you — the credits are added
              automatically once the payment goes through.
            </div>
          )}
        </div>
      </div>

      {left <= 0 && (
        <div className="rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm">
          <strong>Out of credits.</strong> Reminders, bill copies and broadcasts are queued and will go out by themselves as
          soon as credits are added. Nothing has been lost and nothing needs re-doing.
        </div>
      )}
      {left > 0 && left < 100 && (
        <div className="rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-sm">
          <strong>{int(left)} credits left.</strong> Worth topping up before they run out, so reminders do not stop
          mid-month.
        </div>
      )}

      {/* Top-ups: what was paid, and what it bought. */}
      <div>
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-sm font-medium">Credits bought</h3>
        </div>
        {topups.isLoading ? (
          <Spinner />
        ) : !topups.data?.length ? (
          <p className="text-sm text-muted-foreground">No credits bought yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>When</TableHead>
                <TableHead className="text-right">Credits</TableHead>
                <TableHead className="text-right">Paid</TableHead>
                <TableHead className="text-right">Each</TableHead>
                <TableHead>Reference</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {topups.data.map((t) => (
                <TableRow key={t.id}>
                  <TableCell>{dateTimeDMY(t.created_at)}</TableCell>
                  <TableCell className="text-right tabular-nums">{int(t.credits)}</TableCell>
                  <TableCell className="text-right tabular-nums">{money(Number(t.amount_paise) / 100)}</TableCell>
                  <TableCell className="text-right tabular-nums">{money(t.rate_paise / 100)}</TableCell>
                  <TableCell className="text-xs text-muted-foreground">{t.payment_id ?? t.note ?? '—'}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>

      {/* The ledger itself. This is the answer to "where did they go". */}
      <div>
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-sm font-medium">Every credit in and out</h3>
          <Button variant="outline" size="sm" className="h-8" onClick={onExport}>
            <Download className="mr-1 h-4 w-4" /> Export
          </Button>
        </div>
        {ledger.isLoading ? (
          <Spinner />
        ) : !ledger.data?.rows.length ? (
          <p className="text-sm text-muted-foreground">Nothing yet.</p>
        ) : (
          <>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>When</TableHead>
                  <TableHead>What</TableHead>
                  <TableHead className="text-right">In</TableHead>
                  <TableHead className="text-right">Out</TableHead>
                  <TableHead>Note</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {ledger.data.rows.map((r) => (
                  <TableRow key={r.id}>
                    <TableCell>{dateTimeDMY(r.created_at)}</TableCell>
                    <TableCell>
                      <Badge variant={r.delta > 0 ? 'default' : 'outline'}>{reasonLabel(r)}</Badge>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{r.delta > 0 ? int(r.delta) : ''}</TableCell>
                    <TableCell className="text-right tabular-nums">{r.delta < 0 ? int(-r.delta) : ''}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{r.note ?? ''}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            <Pager
              page={page}
              pageSize={pageSize}
              total={ledger.data.total}
              onPage={setPage}
              onPageSize={(n) => { setPageSize(n); setPage(1); }}
            />
          </>
        )}
      </div>
    </div>
  );
}
