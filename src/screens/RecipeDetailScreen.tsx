import { useEffect, useLayoutEffect } from 'react';
import {
  Alert,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  ExternalLink,
  Heart,
  Pencil,
  Trash2,
  UtensilsCrossed,
} from 'lucide-react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import { LlamaMascot } from '../components/LlamaMascot';
import { MeasurementGuideCard } from '../components/MeasurementGuideCard';
import { TagChip } from '../components/TagChip';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { formatDateMDY } from '../lib/formatDate';
import { useRecipesStore } from '../store/recipesStore';
import type { RootStackParamList } from '../navigation/RootStack';

type Props = NativeStackScreenProps<RootStackParamList, 'RecipeDetail'>;

export function RecipeDetailScreen({ route, navigation }: Props) {
  const { id } = route.params;
  const recipe = useRecipesStore((s) => s.recipes[id]);
  const toggleFavorite = useRecipesStore((s) => s.toggleFavorite);
  const deleteRecipe = useRecipesStore((s) => s.deleteRecipe);
  const insets = useSafeAreaInsets();

  useEffect(() => {
    if (!recipe) {
      navigation.goBack();
    }
  }, [recipe, navigation]);

  useLayoutEffect(() => {
    if (!recipe) return;
    navigation.setOptions({
      headerRight: () => (
        <View style={styles.headerActions}>
          <Pressable
            onPress={() => toggleFavorite(recipe.id)}
            hitSlop={10}
            accessibilityLabel={recipe.favorite ? 'Unfavorite' : 'Favorite'}
            style={styles.headerBtn}
          >
            <Heart
              size={22}
              color={colors.accent}
              fill={recipe.favorite ? colors.accent : 'transparent'}
              strokeWidth={2}
            />
          </Pressable>
          <Pressable
            onPress={() => navigation.navigate('RecipeEditor', { id: recipe.id })}
            hitSlop={10}
            accessibilityLabel="Edit"
            style={styles.headerBtn}
          >
            <Pencil size={20} color={colors.textPrimary} strokeWidth={2} />
          </Pressable>
        </View>
      ),
    });
  }, [navigation, recipe, toggleFavorite]);

  if (!recipe) return <View style={styles.container} />;

  const handleDelete = () => {
    Alert.alert(
      'Delete recipe?',
      `"${recipe.title}" will be permanently removed.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            deleteRecipe(recipe.id);
            navigation.goBack();
          },
        },
      ],
    );
  };

  const timeParts: string[] = [];
  if (recipe.servings != null) {
    timeParts.push(
      `${recipe.servings} serving${recipe.servings === 1 ? '' : 's'}`,
    );
  }
  const cookMins = recipe.cookTimeMinutes ?? recipe.ovenTimeMinutes;
  if (cookMins != null) {
    timeParts.push(`Cook ${cookMins}m`);
  }

  const metaParts: string[] = [];
  metaParts.push(`Added ${formatDateMDY(recipe.createdAt)}`);
  if (recipe.lastCookedAt) {
    metaParts.push(`Last cooked ${formatDateMDY(recipe.lastCookedAt)}`);
  }
  if (recipe.cookCount > 0) {
    metaParts.push(
      `Cooked ${recipe.cookCount} time${recipe.cookCount === 1 ? '' : 's'}`,
    );
  }

  return (
    <View style={styles.container}>
      <ScrollView
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom + 100 },
        ]}
      >
        <Text style={styles.title}>{recipe.title}</Text>

        {recipe.description ? (
          <Text style={styles.description}>{recipe.description}</Text>
        ) : null}

        {timeParts.length > 0 ? (
          <Text style={styles.timesRow}>{timeParts.join('  ·  ')}</Text>
        ) : null}

        {recipe.tags.length > 0 ? (
          <View style={styles.tagsRow}>
            {recipe.tags.map((t) => (
              <TagChip key={t} label={t} />
            ))}
          </View>
        ) : null}

        {recipe.ingredients.length > 0 ? (
          <View>
            <Text style={styles.sectionHeading}>Ingredients</Text>
            <View style={styles.ingredientsList}>
              {recipe.ingredients.map((ingredient) => (
                <View key={ingredient.id} style={styles.ingredientRow}>
                  <View style={styles.dot} />
                  <Text style={styles.ingredientText}>
                    {[ingredient.quantity, ingredient.unit, ingredient.name]
                      .filter(Boolean)
                      .join(' ')}
                  </Text>
                </View>
              ))}
            </View>
            <MeasurementGuideCard style={styles.measurementGuide} />
          </View>
        ) : null}

        {recipe.steps.length > 0 ? (
          <View>
            <Text style={styles.sectionHeading}>Steps</Text>
            <View style={styles.stepsList}>
              {recipe.steps.map((step, idx) => (
                <View key={step.id} style={styles.stepRow}>
                  <Text style={styles.stepNumber}>{idx + 1}.</Text>
                  <Text style={styles.stepText}>{step.text}</Text>
                </View>
              ))}
            </View>
          </View>
        ) : null}

        {recipe.notes.trim().length > 0 ? (
          <View>
            <Text style={styles.sectionHeading}>Notes</Text>
            <View style={styles.notesBox}>
              <Text style={styles.notesText}>{recipe.notes}</Text>
            </View>
          </View>
        ) : null}

        {recipe.sourceUrl ? (
          <View>
            <Text style={styles.sectionHeading}>Reference</Text>
            <Pressable
              onPress={() =>
                Linking.openURL(recipe.sourceUrl!).catch(() => {
                  Alert.alert('Could not open link', recipe.sourceUrl!);
                })
              }
              style={styles.sourceLink}
              accessibilityLabel="Open recipe source"
            >
              <ExternalLink size={16} color={colors.accent} strokeWidth={2} />
              <Text style={styles.sourceLinkText} numberOfLines={2}>
                {recipe.sourceUrl}
              </Text>
            </Pressable>
          </View>
        ) : null}

        <View style={styles.signatureRow}>
          <LlamaMascot size={36} />
          <Text style={styles.metaFooter}>{metaParts.join(' · ')}</Text>
        </View>

        <Pressable
          onPress={handleDelete}
          style={styles.deleteInline}
          accessibilityLabel="Delete recipe"
        >
          <Trash2 size={16} color={colors.destructive} strokeWidth={2} />
          <Text style={styles.deleteInlineText}>Delete recipe</Text>
        </Pressable>
      </ScrollView>

      <View style={[styles.actionBar, { paddingBottom: insets.bottom + spacing.md }]}>
        <Pressable
          style={styles.cookBtn}
          onPress={() => navigation.navigate('CookMode', { id: recipe.id })}
        >
          <UtensilsCrossed size={20} color="#FFFDF8" strokeWidth={2.25} />
          <Text style={styles.cookBtnText}>Start Cooking</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  headerActions: {
    flexDirection: 'row',
    gap: spacing.md,
  },
  headerBtn: {
    padding: spacing.xs,
  },
  content: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  title: {
    ...textStyles.recipeTitle,
    fontFamily: fontFamilies.displayBold,
    color: colors.textPrimary,
  },
  description: {
    ...textStyles.body,
    color: colors.textSecondary,
  },
  timesRow: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  tagsRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  sectionHeading: {
    ...textStyles.sectionHeading,
    color: colors.textPrimary,
    marginTop: spacing.lg,
    marginBottom: spacing.sm,
  },
  ingredientsList: {
    gap: spacing.xs,
  },
  ingredientRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.sm + 2,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.accent,
  },
  ingredientText: {
    ...textStyles.ingredient,
    color: colors.textPrimary,
    flex: 1,
  },
  measurementGuide: {
    marginTop: spacing.md,
  },
  stepsList: {
    gap: spacing.md,
  },
  stepRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.md,
  },
  stepNumber: {
    ...textStyles.body,
    fontFamily: fontFamilies.displayBold,
    color: colors.accent,
    minWidth: 28,
    fontVariant: ['tabular-nums'],
  },
  stepText: {
    ...textStyles.body,
    color: colors.textPrimary,
    flex: 1,
  },
  notesBox: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    padding: spacing.md,
  },
  sourceLink: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm + 2,
  },
  sourceLinkText: {
    ...textStyles.body,
    color: colors.accent,
    flex: 1,
  },
  notesText: {
    ...textStyles.body,
    color: colors.textPrimary,
  },
  signatureRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    marginTop: spacing.xl,
  },
  metaFooter: {
    ...textStyles.caption,
    color: colors.textSecondary,
    flex: 1,
  },
  deleteInline: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    marginTop: spacing.lg,
    padding: spacing.sm,
    alignSelf: 'flex-start',
  },
  deleteInlineText: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 14,
    color: colors.destructive,
  },
  actionBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    padding: spacing.lg,
    paddingTop: spacing.md,
    backgroundColor: colors.background,
    borderTopWidth: 1,
    borderTopColor: colors.divider,
  },
  cookBtn: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.accent,
    paddingVertical: spacing.md,
    borderRadius: radius.md,
  },
  cookBtnText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 17,
    color: '#FFFDF8',
  },
});
