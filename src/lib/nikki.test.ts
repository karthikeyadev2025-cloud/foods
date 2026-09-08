import { describe, expect, it } from 'vitest';
import { renderTemplate, unknownPlaceholders } from './nikki';

describe('renderTemplate', () => {
  it('fills known placeholders and leaves unknown ones visible, like the DB', () => {
    expect(renderTemplate('Hi {{name}}, {{outstanding}} due. {{x}}', { name: 'Ravi', outstanding: '2,688.00' })).toBe('Hi Ravi, 2,688.00 due. {{x}}');
  });
  it('handles Telugu bodies and repeated keys', () => {
    expect(renderTemplate('{{name}} గారు, {{name}}!', { name: 'రవి' })).toBe('రవి గారు, రవి!');
  });
  it('treats null as empty', () => {
    expect(renderTemplate('[{{town}}]', { town: null })).toBe('[]');
  });
});

describe('unknownPlaceholders', () => {
  it('flags typos only', () => {
    expect(unknownPlaceholders('{{name}} {{outstandng}} {{ org }} {{amount}}')).toEqual(['outstandng']);
  });
});
