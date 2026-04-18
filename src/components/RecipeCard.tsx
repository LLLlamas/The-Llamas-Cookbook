import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Heart } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { radius, shadow, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { formatDateMDY } from '../lib/formatDate';
import type { Recipe } from '../types/recipe';

type Props = {
  recipe: Recipe;
  onPress: () => void;
};

export function RecipeCard({ recipe, onPress }: Props) {
  const meta: string[] = [];
  if (recipe.lastCookedAt) {
    meta.push(`Last cooked ${formatDateMDY(recipe.lastCookedAt)}`);
  }
  if (recipe.cookCount > 0) {
    meta.push(
      `Cooked ${recipe.cookCount} time${recipe.cookCount === 1 ? '' : 's'}`,
    );
  }

  return (
    <Pressable
      style={({ pressed }) => [styles.card, pressed && styles.cardPressed]}
      onPress={onPress}
    >
      <View style={styles.header}>
        <Text style={styles.title} numberOfLines={2}>
          {recipe.title}
        </Text>
        {recipe.favorite ? (
          <Heart
            size={18}
            color={colors.accent}
            fill={colors.accent}
            strokeWidth={2}
          />
        ) : null}
      </View>
      {recipe.description ? (
        <Text style={styles.subtitle} numberOfLines={2}>
          {recipe.description}
        </Text>
      ) : null}
      {meta.length > 0 ? (
        <Text style={styles.meta}>{meta.join(' · ')}</Text>
      ) : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.lg,
    gap: spacing.xs,
    ...shadow.card,
  },
  cardPressed: {
    opacity: 0.85,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: spacing.md,
  },
  title: {
    ...textStyles.sectionHeading,
    fontFamily: fontFamilies.displayBold,
    color: colors.textPrimary,
    flex: 1,
  },
  subtitle: {
    ...textStyles.body,
    color: colors.textSecondary,
  },
  meta: {
    ...textStyles.caption,
    color: colors.textSecondary,
    marginTop: spacing.xs,
  },
});
