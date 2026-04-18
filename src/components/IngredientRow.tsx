import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Trash2 } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import type { Ingredient } from '../types/recipe';

type Props = {
  ingredient: Ingredient;
  onDelete?: () => void;
};

export function IngredientRow({ ingredient, onDelete }: Props) {
  const qty = ingredient.quantity?.trim();
  const unit = ingredient.unit?.trim();

  return (
    <View style={styles.row}>
      <View style={styles.qtyBlock}>
        {qty ? <Text style={styles.qty}>{qty}</Text> : null}
        {unit ? <Text style={styles.unit}>{unit}</Text> : null}
      </View>
      <Text style={styles.name}>{ingredient.name}</Text>
      {onDelete ? (
        <Pressable
          onPress={onDelete}
          accessibilityLabel={`Delete ${ingredient.name}`}
          hitSlop={10}
          style={styles.deleteBtn}
        >
          <Trash2 color={colors.textSecondary} size={18} strokeWidth={2} />
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.sm,
    gap: spacing.md,
  },
  qtyBlock: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 4,
    minWidth: 72,
  },
  qty: {
    ...textStyles.ingredient,
    fontFamily: fontFamilies.bodySemibold,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
  unit: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  name: {
    ...textStyles.ingredient,
    color: colors.textPrimary,
    flex: 1,
  },
  deleteBtn: {
    padding: spacing.xs,
  },
});
