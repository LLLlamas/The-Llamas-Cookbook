import { StyleSheet, Text, View } from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { LlamaMascot } from '../components/LlamaMascot';
import { colors } from '../theme/colors';
import { spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'Settings'>;

export function SettingsScreen(_props: Props) {
  return (
    <View style={styles.container}>
      <View style={styles.llamaWrap}>
        <LlamaMascot size={96} />
      </View>
      <Text style={styles.title}>Llamas Cookbook</Text>
      <Text style={styles.body}>
        Minimal for MVP: about + data export live here.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
    padding: spacing.xl,
    alignItems: 'center',
    gap: spacing.md,
  },
  llamaWrap: {
    marginTop: spacing.lg,
  },
  title: {
    ...textStyles.recipeTitle,
    fontFamily: fontFamilies.displayBold,
    color: colors.textPrimary,
    textAlign: 'center',
  },
  body: {
    ...textStyles.body,
    color: colors.textSecondary,
    textAlign: 'center',
  },
});
