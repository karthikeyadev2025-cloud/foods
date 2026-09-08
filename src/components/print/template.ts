import { int } from '@/lib/format';
import type { Database } from '@/types/supabase';

/** What the print sheet needs from the signed-in user's org (v_me). */
export type PrintOrg = Partial<Database['public']['Views']['v_me']['Row']>;

export interface PrintTemplateLike {
  paper: string;
  show_fields: unknown;
  terms: string[] | null;
  header_html: string | null;
  footer_html: string | null;
}

/** A block prints unless the template stores an explicit false for it. */
export function showField(template: PrintTemplateLike | null | undefined, key: string): boolean {
  const sf = template?.show_fields;
  if (!sf || typeof sf !== 'object' || Array.isArray(sf)) return true;
  const v = (sf as Record<string, unknown>)[key];
  return v === undefined ? true : Boolean(v);
}

/** The three printed trade terms, worded from the business profile. */
export function defaultTerms(org: PrintOrg | null | undefined): string[] {
  return [
    `DAMAGE OR BREAKAGE ONLY ${int(org?.breakage_recovery_pct ?? 0)}% RECOVERY.`,
    `Interest at ${int(org?.interest_pct_pa ?? 0)}% will be charged from the date of the bill if not paid within ${int(org?.credit_days ?? 0)} days.`,
    `Subject to ${org?.jurisdiction ?? ''} jurisdiction only.`,
  ];
}

/** Custom terms may carry {breakage} {interest} {credit_days} {jurisdiction}. */
export function fillTerms(terms: string[] | null | undefined, org: PrintOrg | null | undefined): string[] {
  const list = terms && terms.length ? terms : defaultTerms(org);
  const vars: Record<string, string> = {
    breakage: int(org?.breakage_recovery_pct ?? 0),
    interest: int(org?.interest_pct_pa ?? 0),
    credit_days: int(org?.credit_days ?? 0),
    jurisdiction: org?.jurisdiction ?? '',
  };
  return list.map((t) => t.replace(/\{(\w+)\}/g, (m, k: string) => vars[k] ?? m));
}
