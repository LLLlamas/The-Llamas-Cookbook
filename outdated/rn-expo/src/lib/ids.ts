import { randomUUID } from 'expo-crypto';
import type { ID } from '../types/recipe';

export const newId = (): ID => randomUUID();
