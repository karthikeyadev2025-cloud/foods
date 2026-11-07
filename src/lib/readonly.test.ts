import { afterEach, describe, expect, it } from 'vitest';
import { assertWritable, isReadOnly, READ_ONLY_MESSAGE, ReadOnlyError, setReadOnly } from './readonly';

afterEach(() => setReadOnly(false));

describe('the frozen app', () => {
  it('lets everything through until the licence says otherwise', () => {
    expect(isReadOnly()).toBe(false);
    expect(() => assertWritable()).not.toThrow();
  });

  it('refuses writes once the licence has lapsed', () => {
    setReadOnly(true);
    expect(isReadOnly()).toBe(true);
    expect(() => assertWritable()).toThrow(ReadOnlyError);
  });

  /*
    The message is read by a shopkeeper at a counter, not by a developer. It
    has to say what cannot be done, what still can, and why — without the word
    "licence", "403" or "permission", none of which tell him to ring anybody.
  */
  it('says it in words a shopkeeper can act on', () => {
    expect(READ_ONLY_MESSAGE).toMatch(/read-only/i);
    expect(READ_ONLY_MESSAGE).toMatch(/nothing new can be saved/i);
    expect(READ_ONLY_MESSAGE).toMatch(/printed and exported/i);
    expect(READ_ONLY_MESSAGE).not.toMatch(/403|error|permission denied/i);
  });

  it('lifts the moment the licence says so, with nobody signing out', () => {
    setReadOnly(true);
    expect(() => assertWritable()).toThrow();
    setReadOnly(false);               // the half-hourly licence check, after payment
    expect(() => assertWritable()).not.toThrow();
  });
});
