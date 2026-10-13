package dns

type ExternalReadOnly struct{}

func (ExternalReadOnly) Mode() Mode { return ModeReadOnly }

func (ExternalReadOnly) PlanUpsert(Binding, Record) (MutationPlan, error) {
	return MutationPlan{}, ErrReadOnly
}

func (ExternalReadOnly) PlanDelete(Binding, Record) (MutationPlan, error) {
	return MutationPlan{}, ErrReadOnly
}
