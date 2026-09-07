import { z } from 'zod';

export const loginSchema = z.object({
  email: z.string().trim().min(1, 'Email is required').email('Enter a valid email'),
  password: z.string().min(1, 'Password is required'),
});
export type LoginInput = z.infer<typeof loginSchema>;

export const bootstrapSchema = z.object({
  orgName: z.string().trim().min(1, 'Organisation name is required').max(120),
  fullName: z.string().trim().min(1, 'Your name is required').max(120),
  phone: z.string().trim().max(20).optional().or(z.literal('')),
});
export type BootstrapFormInput = z.infer<typeof bootstrapSchema>;
