import { useRef, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { textStyles } from '../theme/typography';
import { newId } from '../lib/ids';
import type { Ingredient } from '../types/recipe';
import { FractionChips } from './FractionChips';
import { UnitChips } from './UnitChips';

type Props = {
  onAdd: (ingredient: Omit<Ingredient, 'order'>) => void;
  autoFocus?: boolean;
};

export function IngredientQuickAdd({ onAdd, autoFocus }: Props) {
  const [quantity, setQuantity] = useState('');
  const [unit, setUnit] = useState('');
  const [name, setName] = useState('');

  const qtyRef = useRef<TextInput>(null);
  const unitRef = useRef<TextInput>(null);
  const nameRef = useRef<TextInput>(null);

  const submit = () => {
    const trimmed = name.trim();
    if (!trimmed) {
      nameRef.current?.focus();
      return;
    }
    onAdd({
      id: newId(),
      quantity: quantity.trim() || undefined,
      unit: unit.trim() || undefined,
      name: trimmed,
    });
    setQuantity('');
    setUnit('');
    setName('');
    qtyRef.current?.focus();
  };

  return (
    <View style={styles.wrap}>
      <View style={styles.row}>
        <TextInput
          ref={qtyRef}
          value={quantity}
          onChangeText={setQuantity}
          placeholder="Qty"
          placeholderTextColor={colors.textSecondary}
          style={[styles.input, styles.qty]}
          keyboardType="decimal-pad"
          returnKeyType="next"
          blurOnSubmit={false}
          autoFocus={autoFocus}
          onSubmitEditing={() => unitRef.current?.focus()}
        />
        <TextInput
          ref={unitRef}
          value={unit}
          onChangeText={setUnit}
          placeholder="Unit"
          placeholderTextColor={colors.textSecondary}
          style={[styles.input, styles.unit]}
          returnKeyType="next"
          autoCapitalize="none"
          autoCorrect={false}
          blurOnSubmit={false}
          onSubmitEditing={() => nameRef.current?.focus()}
        />
        <TextInput
          ref={nameRef}
          value={name}
          onChangeText={setName}
          placeholder="Ingredient"
          placeholderTextColor={colors.textSecondary}
          style={[styles.input, styles.name]}
          returnKeyType="done"
          blurOnSubmit={false}
          onSubmitEditing={submit}
        />
      </View>
      <FractionChips onPick={setQuantity} currentValue={quantity} />
      <UnitChips onPick={setUnit} currentValue={unit} />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.sm,
    borderWidth: 1,
    borderColor: colors.divider,
    gap: spacing.xs,
  },
  row: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  input: {
    ...textStyles.body,
    color: colors.textPrimary,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.sm,
  },
  qty: {
    flex: 1,
    minWidth: 44,
  },
  unit: {
    flex: 1.2,
    minWidth: 56,
  },
  name: {
    flex: 3,
  },
});
