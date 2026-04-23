import AsyncStorage from '@react-native-async-storage/async-storage';
import { createJSONStorage } from 'zustand/middleware';

export const RECIPES_STORAGE_KEY = 'llamas-cookbook:recipes:v1';

export const zustandAsyncStorage = createJSONStorage(() => AsyncStorage);
