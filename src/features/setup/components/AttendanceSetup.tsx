import { PayrollPanel } from './PayrollPanel';
import { PunchlyPanel } from './PunchlyPanel';

/**
 * Everything the wage sheet needs to be right, on one page: how a day is
 * counted and paid, the calendar, the kinds of leave — and then the Punchly
 * key and which phone-app person is which staff member.
 */
export function AttendanceSetup() {
  return (
    <div className="space-y-10">
      <PayrollPanel />
      <PunchlyPanel />
    </div>
  );
}
