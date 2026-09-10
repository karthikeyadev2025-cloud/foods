import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, CheckCircle2, Download, FileSpreadsheet, Upload } from 'lucide-react';
import { useMemo, useState, type ChangeEvent } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { dateTimeDMY, int, toISODate } from '@/lib/format';
import { cn } from '@/lib/utils';
import { listImportJobs, listStaff, runImport, stockLocationsApi, type ImportResult } from '../api';
import { autoMap, buildRows, missingRequired, parseSpreadsheet, type ColumnMap, type ParsedFile } from '../import/parse';
import { groupProblems } from '../import/problems';
import { IMPORT_TARGETS, findTarget, type ImportTarget } from '../import/targets';

type Step = 'source' | 'map' | 'preview' | 'done';

const JOBS_KEY = ['setup', 'import_jobs'] as const;

/**
 * Upload → map columns → dry run → commit. The server function does the work
 * (db/07_import.sql) so the same rules apply whether rows come from a file or
 * from the bundled seed files.
 */
export function ImportPanel({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const queryClient = useQueryClient();
  const [step, setStep] = useState<Step>('source');
  const [targetKey, setTargetKey] = useState<ImportTarget['key']>('items');
  const [file, setFile] = useState<ParsedFile | null>(null);
  const [map, setMap] = useState<ColumnMap>({});
  const [locationId, setLocationId] = useState('');
  const [txnDate, setTxnDate] = useState(toISODate());
  const [result, setResult] = useState<ImportResult | null>(null);
  const [loadingFile, setLoadingFile] = useState(false);
  // The workbook as read, so another sheet can be opened without re-uploading.
  const [book, setBook] = useState<ArrayBuffer | null>(null);
  const [createLookups, setCreateLookups] = useState(false);

  const target = findTarget(targetKey) ?? IMPORT_TARGETS[0];
  const locations = useQuery({ queryKey: ['setup', 'stock_locations'], queryFn: stockLocationsApi.list, enabled: Boolean(target?.needsLocation) });
  const canEdit = perms.canEdit('setup');

  const loadParsed = (parsed: ParsedFile) => {
    if (!target) return;
    if (parsed.headers.length === 0 || parsed.rows.length === 0) {
      toast({ variant: 'destructive', title: 'Empty file', description: 'The first sheet has no header row or no data rows.' });
      return;
    }
    setFile(parsed);
    setMap(autoMap(parsed.headers, target.fields));
    setResult(null);
    setStep('map');
  };

  const onFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    e.target.value = '';
    if (!f) return;
    setLoadingFile(true);
    try {
      const buf = await f.arrayBuffer();
      setBook(buf);
      loadParsed(parseSpreadsheet(buf, f.name));
    } catch (err) {
      toastError(err, 'Could not read the file');
    } finally {
      setLoadingFile(false);
    }
  };

  /**
   * Switch sheets without choosing the file again. A workbook with a sheet per
   * kind of data is the normal way people keep this, and until now the import
   * read the first one and said nothing about the others.
   */
  const onSheet = (sheet: string) => {
    if (!book || !file) return;
    try {
      loadParsed(parseSpreadsheet(book, file.name, sheet));
    } catch (err) {
      toastError(err, 'Could not read that sheet');
    }
  };

  const onBundled = async (path: string) => {
    setLoadingFile(true);
    try {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`Could not fetch ${path} (${res.status})`);
      loadParsed(parseSpreadsheet(await res.text(), path.split('/').pop() ?? path));
    } catch (err) {
      toastError(err, 'Could not load the bundled file');
    } finally {
      setLoadingFile(false);
    }
  };

  const options = useMemo(
    () => ({
      ...(target?.needsLocation ? { location_id: locationId, txn_date: txnDate } : {}),
      ...(target?.hasLookups && createLookups ? { create_lookups: true } : {}),
    }),
    [target, locationId, txnDate, createLookups],
  );
  const rows = useMemo(() => (file ? buildRows(file, map) : []), [file, map]);
  const problems = useMemo(() => groupProblems(result?.error_rows ?? []), [result]);
  const missing = target ? missingRequired(map, target.fields) : [];
  const optionsMissing = Boolean(target?.needsLocation) && !locationId;

  const dryRun = useMutation({
    mutationFn: () => runImport(target?.key ?? 'items', rows, options, true),
    onSuccess: (r) => {
      setResult(r);
      setStep('preview');
    },
    onError: (err) => toastError(err, 'Dry run failed'),
  });

  const commit = useMutation({
    mutationFn: () => runImport(target?.key ?? 'items', rows, options, false),
    onSuccess: async (r) => {
      setResult(r);
      setStep('done');
      await queryClient.invalidateQueries({ queryKey: ['setup'] });
      toast({ title: `Imported ${int(r.ok)} rows`, description: r.errors ? `${int(r.errors)} rows had errors — download them below.` : undefined });
    },
    onError: (err) => toastError(err, 'Import failed'),
  });

  const downloadErrors = () => {
    if (!result || !target) return;
    exportToExcel(
      `${target.key}-errors`,
      result.error_rows.map((e) => ({ Row: e.row, Error: e.error, ...e.data })),
      'Errors',
    );
  };

  const reset = () => {
    setFile(null);
    setMap({});
    setResult(null);
    setStep('source');
  };

  if (!target) return null;

  return (
    <section className="space-y-4">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Import data</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          Upload an Excel or CSV file, map its columns, check every row, then import. Bad rows are reported and
          downloadable; good rows still load. Re-importing the same file changes nothing.
        </p>
      </div>

      <ol className="flex flex-wrap gap-1 text-xs" aria-label="Import steps">
        {(['source', 'map', 'preview', 'done'] as Step[]).map((s, i) => (
          <li
            key={s}
            aria-current={step === s ? 'step' : undefined}
            className={cn('rounded-full border px-2.5 py-1', step === s ? 'border-primary bg-primary text-primary-foreground' : 'text-muted-foreground')}
          >
            {i + 1}. {s === 'source' ? 'Choose file' : s === 'map' ? 'Map columns' : s === 'preview' ? 'Check' : 'Done'}
          </li>
        ))}
      </ol>

      {step === 'source' && (
        <div className="grid gap-4 md:grid-cols-[18rem_1fr]">
          <div className="space-y-2">
            <div className="text-sm font-medium">What are you importing?</div>
            {IMPORT_TARGETS.map((t) => (
              <label
                key={t.key}
                className={cn(
                  'flex cursor-pointer items-start gap-2 rounded-md border p-2 text-sm',
                  t.key === target.key && 'border-primary bg-primary/5',
                )}
              >
                <input
                  type="radio"
                  name="import-target"
                  className="mt-1 accent-primary"
                  checked={t.key === target.key}
                  onChange={() => setTargetKey(t.key)}
                />
                <span>
                  <span className="font-medium">{t.label}</span>
                  <span className="block text-xs text-muted-foreground">{t.description}</span>
                </span>
              </label>
            ))}
          </div>
          <div className="space-y-3">
            <div className="rounded-md border border-dashed p-4">
              <label htmlFor="import-file" className="flex cursor-pointer flex-col items-center gap-2 text-sm">
                <Upload className="h-6 w-6 text-muted-foreground" aria-hidden />
                <span className="font-medium">Choose an .xlsx, .xls or .csv file</span>
                <span className="text-xs text-muted-foreground">First row is the headings. A file with several sheets lets you pick one.</span>
                <Input id="import-file" type="file" accept=".xlsx,.xls,.csv" className="max-w-xs" onChange={onFile} disabled={!canEdit || loadingFile} />
              </label>
            </div>

            {/*
              A blank template teaches the column names; this one is filled in,
              so the first import can be tried end to end before anybody types
              two hundred rows of their own.
            */}
            <div className="flex items-start justify-between gap-3 rounded-md border p-2 text-sm">
              <span>
                <span className="flex items-center gap-1 font-medium">
                  <FileSpreadsheet className="h-4 w-4" aria-hidden /> Sample file
                </span>
                <span className="block text-xs text-muted-foreground">
                  One sheet per kind — sections, items, customers, opening stock, rates — with the right headings and a
                  few rows filled in. Open it, replace the rows with yours, and upload it.
                </span>
              </span>
              <Button asChild size="sm" variant="outline">
                <a href="/seed/sample-import.xlsx" download>
                  <Download /> Download
                </a>
              </Button>
            </div>
            {target.bundled && (
              <div className="space-y-2">
                <div className="text-sm font-medium">Or use the client&apos;s own data, already decoded</div>
                {target.bundled.map((b) => (
                  <div key={b.path} className="flex items-start justify-between gap-3 rounded-md border p-2 text-sm">
                    <span>
                      <span className="flex items-center gap-1 font-medium">
                        <FileSpreadsheet className="h-4 w-4" aria-hidden /> {b.label}
                      </span>
                      {b.note && <span className="block text-xs text-muted-foreground">{b.note}</span>}
                    </span>
                    <Button size="sm" variant="secondary" onClick={() => onBundled(b.path)} disabled={!canEdit || loadingFile}>
                      Use this
                    </Button>
                  </div>
                ))}
              </div>
            )}
            {loadingFile && <Spinner label="Reading file…" />}
            {!canEdit && <p className="text-sm text-muted-foreground">Your role cannot import data.</p>}
          </div>
        </div>
      )}

      {step === 'map' && file && (
        <div className="space-y-3">
          <p className="text-sm">
            <span className="font-medium">{file.name}</span>
            {file.sheets.length > 1 && <> — sheet <span className="font-medium">{file.sheet}</span></>}
            {' — '}{int(file.rows.length)} rows, {file.headers.length} columns.
            Match each field to a column; required fields are marked.
          </p>
          {file.sheets.length > 1 && (
            <Field label="Sheet" htmlFor="im-sheet" help="This file has more than one sheet. Only the one chosen here is imported.">
              <NativeSelect id="im-sheet" className="h-8 w-64" value={file.sheet} onChange={(ev) => onSheet(ev.target.value)}>
                {file.sheets.map((s) => (
                  <option key={s} value={s}>{s}</option>
                ))}
              </NativeSelect>
            </Field>
          )}
          <div className="rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Field</TableHead>
                  <TableHead>Column in your file</TableHead>
                  <TableHead>First value</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {target.fields.map((f) => {
                  const idx = map[f.key] ?? -1;
                  return (
                    <TableRow key={f.key}>
                      <TableCell>
                        <div className="font-medium">
                          {f.label}
                          {f.required && <span className="text-destructive"> *</span>}
                        </div>
                        {f.hint && <div className="text-xs text-muted-foreground">{f.hint}</div>}
                      </TableCell>
                      <TableCell>
                        <NativeSelect
                          aria-label={`Column for ${f.label}`}
                          value={idx}
                          onChange={(e) => setMap({ ...map, [f.key]: Number(e.target.value) })}
                          className={cn('max-w-xs', f.required && idx < 0 && 'border-destructive')}
                        >
                          <option value={-1}>— not in file —</option>
                          {file.headers.map((h, i) => (
                            <option key={i} value={i}>
                              {h || `(column ${i + 1})`}
                            </option>
                          ))}
                        </NativeSelect>
                      </TableCell>
                      <TableCell className="text-muted-foreground">{idx >= 0 ? file.rows[0]?.[idx] : ''}</TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>

          {target.needsLocation && (
            <div className="grid max-w-lg grid-cols-2 gap-3">
              <Field label="Post to location" htmlFor="import-location" error={optionsMissing ? 'Choose a location' : undefined}>
                <NativeSelect id="import-location" value={locationId} onChange={(e) => setLocationId(e.target.value)}>
                  <option value="">— choose —</option>
                  {(locations.data ?? []).map((l) => (
                    <option key={l.id} value={l.id}>
                      {l.name}
                    </option>
                  ))}
                </NativeSelect>
              </Field>
              <Field label="As on date" htmlFor="import-date">
                <Input id="import-date" type="date" value={txnDate} onChange={(e) => setTxnDate(e.target.value)} />
              </Field>
            </div>
          )}

          {/*
            Pack type and section are optional fields that must match a Setup
            list. Before this, a file naming a pack type Setup had never seen
            lost the whole product — 250 rows, 250 errors, over a label that
            touches no figure. Off by default all the same: this is how "BOX",
            "Box" and "BOZ" become three pack types.
          */}
          {target.hasLookups && (
            <label className="flex max-w-3xl cursor-pointer items-start gap-2 rounded-md border p-2 text-sm">
              <input
                type="checkbox"
                className="mt-1 accent-primary"
                checked={createLookups}
                onChange={(e) => setCreateLookups(e.target.checked)}
              />
              <span>
                <span className="font-medium">Create missing pack types and sections</span>
                <span className="block text-xs text-muted-foreground">
                  A pack type or section your file names but Setup has never seen is created as it appears, instead of
                  the product being skipped. Check the spelling first — BOX and BOZ would become two pack types.
                </span>
              </span>
            </label>
          )}

          <div className="flex items-center justify-between">
            <Button variant="outline" onClick={reset}>
              Start over
            </Button>
            <div className="flex items-center gap-3">
              {missing.length > 0 && (
                <span className="text-sm text-destructive">Map: {missing.map((m) => m.label).join(', ')}</span>
              )}
              <Button onClick={() => dryRun.mutate()} disabled={missing.length > 0 || optionsMissing || dryRun.isPending}>
                {dryRun.isPending ? 'Checking…' : `Check ${int(rows.length)} rows`}
              </Button>
            </div>
          </div>
        </div>
      )}

      {(step === 'preview' || step === 'done') && result && (
        <div className="space-y-3">
          <div className="grid grid-cols-4 gap-2 text-sm">
            <Stat label="Rows" value={result.total} />
            <Stat label={step === 'done' ? 'Imported' : 'Will import'} value={result.ok} tone="good" />
            <Stat label="Unchanged" value={result.unchanged} />
            <Stat label="Errors" value={result.errors} tone={result.errors ? 'bad' : undefined} />
          </div>

          {step === 'done' && (
            <p className="flex items-center gap-2 text-sm">
              <CheckCircle2 className="h-4 w-4 text-green-700" aria-hidden /> Import committed.
            </p>
          )}

          {result.error_rows.length > 0 && (
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <p className="flex items-center gap-2 text-sm">
                  <AlertTriangle className="h-4 w-4 text-destructive" aria-hidden />
                  {int(result.errors)} rows {step === 'done' ? 'were skipped' : 'will be skipped'}. Fix them in the file and import again — good rows are never duplicated.
                </p>
                <Button variant="outline" size="sm" onClick={downloadErrors}>
                  <Download /> Download error rows
                </Button>
              </div>

              {/*
                What is actually wrong, before the row-by-row list. 250 rows of
                the same sentence reads as 250 problems; it is usually one, and
                the second one is below the fold where nobody sees it until the
                next attempt fails for a reason they could have read here.
              */}
              <div className="rounded-md border border-destructive/40 bg-destructive/5 p-3">
                <p className="text-sm font-medium">
                  {problems.length === 1 ? 'One thing is wrong:' : `${int(problems.length)} things are wrong:`}
                </p>
                <ul className="mt-2 space-y-1.5 text-sm">
                  {problems.map((p) => (
                    <li key={p.message}>
                      <span className="font-medium tabular-nums">{int(p.count)}</span>{' '}
                      {p.count === 1 ? 'row' : 'rows'} — <span className="text-destructive">{p.message}</span>
                      <span className="block text-xs text-muted-foreground">
                        Row {p.rows.join(', ')}
                        {p.more && ' and more'}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>

              <div className="max-h-72 overflow-auto rounded-md border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="w-14">Row</TableHead>
                      <TableHead>Problem</TableHead>
                      <TableHead>Data</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {result.error_rows.slice(0, 200).map((e) => (
                      <TableRow key={e.row}>
                        <TableCell className="num">{e.row}</TableCell>
                        <TableCell className="text-destructive">{e.error}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                          {Object.entries(e.data)
                            .filter(([, v]) => v !== '')
                            .map(([k, v]) => `${k}: ${v}`)
                            .join(' · ')}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            </div>
          )}

          <div className="flex items-center justify-between">
            <Button variant="outline" onClick={step === 'done' ? reset : () => setStep('map')}>
              {step === 'done' ? 'Import another file' : 'Back to mapping'}
            </Button>
            {step === 'preview' && (
              <Button onClick={() => commit.mutate()} disabled={result.ok === 0 || commit.isPending}>
                {commit.isPending ? 'Importing…' : `Import ${int(result.ok)} rows`}
              </Button>
            )}
          </div>
        </div>
      )}

      <ImportHistory />
    </section>
  );
}

function Stat({ label, value, tone }: { label: string; value: number; tone?: 'good' | 'bad' }) {
  return (
    <div className={cn('rounded-md border p-2', tone === 'good' && 'border-green-300 bg-green-50', tone === 'bad' && 'border-red-300 bg-red-50')}>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-lg font-semibold tabular-nums">{int(value)}</div>
    </div>
  );
}

function ImportHistory() {
  const jobs = useQuery({ queryKey: JOBS_KEY, queryFn: listImportJobs });
  const staff = useQuery({ queryKey: ['setup', 'staff'], queryFn: listStaff });
  const who = (id: string | null) => staff.data?.find((s) => s.id === id)?.full_name ?? '—';
  const label = (t: string) => findTarget(t)?.label ?? t;
  if (jobs.isLoading) return <Spinner label="Loading history…" />;
  if (!jobs.data?.length) return null;
  return (
    <div className="space-y-2">
      <h3 className="text-sm font-medium">Recent imports</h3>
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>When</TableHead>
              <TableHead>What</TableHead>
              <TableHead className="text-right">Rows</TableHead>
              <TableHead className="text-right">OK</TableHead>
              <TableHead className="text-right">Errors</TableHead>
              <TableHead>By</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {jobs.data.map((j) => {
              const errs = Array.isArray(j.error_rows) ? j.error_rows.length : 0;
              return (
                <TableRow key={j.id}>
                  <TableCell>{dateTimeDMY(j.created_at)}</TableCell>
                  <TableCell>{label(j.target)}</TableCell>
                  <TableCell className="num">{int(j.total_rows)}</TableCell>
                  <TableCell className="num">{int(j.ok_rows)}</TableCell>
                  <TableCell className="num">{errs ? <Badge variant="destructive">{int(errs)}</Badge> : '0'}</TableCell>
                  <TableCell>{who(j.created_by)}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
