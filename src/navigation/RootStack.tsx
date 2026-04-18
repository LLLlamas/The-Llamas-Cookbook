import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { colors } from '../theme/colors';
import { fontFamilies } from '../theme/typography';
import type { ID } from '../types/recipe';
import { LibraryScreen } from '../screens/LibraryScreen';
import { RecipeDetailScreen } from '../screens/RecipeDetailScreen';
import { RecipeEditorScreen } from '../screens/RecipeEditorScreen';
import { CookModeScreen } from '../screens/CookModeScreen';
import { SettingsScreen } from '../screens/SettingsScreen';

export type RootStackParamList = {
  Library: undefined;
  RecipeDetail: { id: ID };
  RecipeEditor: { id?: ID };
  CookMode: { id: ID };
  Settings: undefined;
};

const Stack = createNativeStackNavigator<RootStackParamList>();

export function RootStack() {
  return (
    <Stack.Navigator
      initialRouteName="Library"
      screenOptions={{
        headerStyle: { backgroundColor: colors.background },
        headerTitleStyle: {
          fontFamily: fontFamilies.display,
          fontSize: 18,
          color: colors.textPrimary,
        },
        headerTintColor: colors.textPrimary,
        headerShadowVisible: false,
        contentStyle: { backgroundColor: colors.background },
      }}
    >
      <Stack.Screen
        name="Library"
        component={LibraryScreen}
        options={{ title: 'Llamas Cookbook' }}
      />
      <Stack.Screen
        name="RecipeDetail"
        component={RecipeDetailScreen}
        options={{ title: '' }}
      />
      <Stack.Screen
        name="RecipeEditor"
        component={RecipeEditorScreen}
        options={{ presentation: 'modal', title: 'New Recipe' }}
      />
      <Stack.Screen
        name="CookMode"
        component={CookModeScreen}
        options={{ presentation: 'fullScreenModal', headerShown: false }}
      />
      <Stack.Screen
        name="Settings"
        component={SettingsScreen}
        options={{ title: 'Settings' }}
      />
    </Stack.Navigator>
  );
}
